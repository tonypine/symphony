defmodule SymphonyElixir.TicketColumns do
  @moduledoc """
  The ticket entity's column catalog: every column a saved view (`SymphonyElixir.Views`) or the
  tickets read (`GET /api/v1/tickets`, `SymphonyElixir.TicketList`) may show or sort by, each with
  its name and type, and the filters a view may select tickets by, each over one column. It is the
  one place they are declared: the views are validated against it, and the reason a view is refused
  names its columns.

  A column's value is read from the ticket's record (`SymphonyElixir.TicketState`), never from
  Linear text; `situation` and `situation_since` are its situation (`SymphonyElixir.Situation`),
  computed only when a view asks for them.
  """

  alias SymphonyElixir.Situation

  @columns [
    %{name: "identifier", type: "identifier", description: "The ticket's identifier."},
    %{name: "title", type: "string", description: "The ticket's title."},
    %{name: "repo", type: "string", description: "The key of the repository the ticket lives in."},
    %{name: "epic", type: "identifier", description: "The identifier of the epic the ticket is a sub-ticket of."},
    %{name: "phase", type: "string", description: "The phase (state) the ticket is in."},
    %{name: "situation", type: "situation", description: "The kind of the ticket's situation."},
    %{name: "situation_since", type: "time", description: "Since when the ticket's situation holds."},
    %{name: "labels", type: "list", description: "The ticket's labels."},
    %{name: "priority", type: "integer", description: "Linear's priority: 0 none, 1 urgent, 2 high, 3 medium, 4 low."},
    %{name: "assignee", type: "string", description: "Who the ticket is assigned to."},
    %{name: "url", type: "string", description: "The ticket's page in Linear."},
    %{name: "created_at", type: "time", description: "When the ticket was created."},
    %{name: "phase_at", type: "time", description: "When the ticket entered its phase."},
    %{name: "updated_at", type: "time", description: "When Symphony last wrote the ticket's record."}
  ]

  # name -> {the column it reads, how it matches}
  @filters [
    {"repo", "repo", :any},
    {"epic", "epic", :epic},
    {"phase", "phase", :any},
    {"situation", "situation", :any},
    {"label", "labels", :contains},
    {"priority", "priority", :any},
    {"since", "updated_at", :after}
  ]

  @situation_columns ~w(situation situation_since)

  @typedoc "One column: its name, its type (`identifier`, `string`, `situation`, `time`, `list`, `integer`) and what it holds."
  @type column :: %{name: String.t(), type: String.t(), description: String.t()}

  @typedoc "How a filter matches its column: any of its values, the epic or its sub-tickets, a label it holds, or after a time."
  @type match :: :any | :epic | :contains | :after

  @doc "Every column, in the catalog's order."
  @spec columns() :: [column()]
  def columns, do: @columns

  @doc "Every column's name, in the catalog's order."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@columns, & &1.name)

  @doc "The type of the column `name`, or nil for a name the catalog doesn't have."
  @spec type(String.t()) :: String.t() | nil
  def type(name), do: Enum.find_value(@columns, &(&1.name == name && &1.type))

  @doc "Every filter's name, in the catalog's order."
  @spec filter_names() :: [String.t()]
  def filter_names, do: Enum.map(@filters, &elem(&1, 0))

  @doc "The column the filter `name` reads and how it matches, or nil for a name the catalog doesn't have."
  @spec filter(String.t()) :: {String.t(), match()} | nil
  def filter(name), do: Enum.find_value(@filters, fn {filter, column, match} -> filter == name && {column, match} end)

  @doc "Whether reading `columns` needs the tickets' situations."
  @spec situation?([String.t()]) :: boolean()
  def situation?(columns), do: Enum.any?(columns, &(&1 in @situation_columns))

  @doc "The situation kinds a `situation` filter may name."
  @spec situation_kinds() :: [String.t()]
  def situation_kinds, do: Situation.kinds()

  @doc """
  The ticket's value of every column but the situation's, from its record
  (`SymphonyElixir.TicketState.normalize/1`).
  """
  @spec values(map()) :: %{String.t() => term()}
  def values(record) do
    %{
      "identifier" => record.issue_identifier,
      "title" => record.title,
      "repo" => record.repo_key,
      "epic" => epic(record.parent),
      "phase" => record.phase,
      "labels" => record.labels,
      "priority" => record.priority,
      "assignee" => record.assignee,
      "url" => record.url,
      "created_at" => record.created_at,
      "phase_at" => record.phase_at,
      "updated_at" => record.updated_at
    }
  end

  @doc "The situation's columns of a ticket (`SymphonyElixir.Situation.t/0`)."
  @spec situation_values(Situation.t()) :: %{String.t() => term()}
  def situation_values(situation), do: %{"situation" => situation.kind, "situation_since" => situation.since}

  defp epic(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp epic(_parent), do: nil
end
