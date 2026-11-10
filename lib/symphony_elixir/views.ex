defmodule SymphonyElixir.Views do
  @moduledoc """
  The saved views of the Tickets page, stored on the server so every client sees the same ones
  (`SymphonyElixir.RunStore`'s views table): a view is a name, filters, columns and a sort over the
  ticket entity, and nothing more.

  - `filters`: a list of `%{column, value}`, each a filter of `SymphonyElixir.TicketColumns`
    (`repo`, `epic`, `phase`, `situation`, `label`, `priority`, `since`); a ticket shows when every
    filter lets it through. `value` is a list of the values any of which matches (a single value is
    taken as a list of one), except `since`'s, one ISO 8601 time the ticket's record was written after.
  - `columns`: the catalog's column names to show, in order (default #{inspect(~w(identifier title phase situation))}).
  - `sort`: `%{column, direction}`, a catalog column and `asc` or `desc` (default `identifier`, `asc`).

  `save/2` creates a view, or updates the one its `id` names; `spec/1` validates a view's filters,
  columns and sort against the catalog, and `query/1` reads the same from a query string's parameters
  (`GET /api/v1/tickets`), so a view and an inline query share one grammar. A refusal is
  `{:error, {:invalid, reason}}`, and a reason for an unknown name lists the catalog's names.
  """

  alias SymphonyElixir.{RunStore, TicketColumns}

  @default_columns ~w(identifier title phase situation)
  @default_sort %{column: "identifier", direction: "asc"}
  @max_name 120
  @priorities 0..4

  @typedoc "A filter: a catalog filter's name and its value (a list of values, or a time for `since`)."
  @type filter :: %{column: String.t(), value: [String.t() | integer()] | String.t()}

  @typedoc "What a view selects: its filters, its columns and its sort."
  @type spec :: %{filters: [filter()], columns: [String.t()], sort: %{column: String.t(), direction: String.t()}}

  @typedoc "A saved view."
  @type t :: %{
          id: String.t(),
          name: String.t(),
          filters: [filter()],
          columns: [String.t()],
          sort: %{column: String.t(), direction: String.t()},
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Every saved view, by name."
  @spec list() :: {:ok, [t()]} | {:error, term()}
  def list do
    with views when is_list(views) <- RunStore.list_views() do
      {:ok, Enum.sort_by(views, &{String.downcase(&1.name), DateTime.to_unix(&1.created_at, :microsecond)})}
    end
  end

  @doc "The saved view with `id`: `{:error, :not_found}` when there is none. A store error raises."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case RunStore.get_view(id) do
      %{} = view -> {:ok, view}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Creates a view from `params` (string keys `name`, `filters`, `columns`, `sort`), or, when `params`
  has an `id`, replaces that view's name, filters, columns and sort and keeps its creation time. An
  `id` no view has is `{:error, :not_found}`. `opts` takes `:now`.
  """
  @spec save(map(), keyword()) :: {:ok, t()} | {:error, {:invalid, String.t()} | :not_found | term()}
  def save(params, opts \\ []) when is_map(params) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, name} <- name(params["name"]),
         {:ok, spec} <- spec(params),
         {:ok, base} <- base(params["id"], now) do
      view = Map.merge(base, Map.merge(spec, %{name: name, updated_at: now}))

      with :ok <- RunStore.put_view(view), do: {:ok, view}
    end
  end

  @doc "Deletes the view with `id`: `{:error, :not_found}` when there is none."
  @spec delete(String.t()) :: :ok | {:error, :not_found | term()}
  def delete(id) when is_binary(id), do: RunStore.delete_view(id)

  @doc """
  The filters, columns and sort of `params` (string keys `filters`, `columns`, `sort`, as a view's
  JSON has them), validated against the column catalog; each missing one takes its default.
  """
  @spec spec(map()) :: {:ok, spec()} | {:error, {:invalid, String.t()}}
  def spec(params) when is_map(params) do
    with {:ok, filters} <- filters(params["filters"]),
         {:ok, columns} <- columns(params["columns"]),
         {:ok, sort} <- sort(params["sort"]) do
      {:ok, %{filters: filters, columns: columns, sort: sort}}
    end
  end

  @doc """
  The spec of an inline query (`GET /api/v1/tickets`): each filter by its name with comma-separated
  values (`epic=TP-1400&situation=waiting_on_you,waiting_for_ci`), `columns` comma-separated,
  `sort` a column and `direction` `asc` or `desc`. Blank parameters are left out.
  """
  @spec query(map()) :: {:ok, spec()} | {:error, {:invalid, String.t()}}
  def query(params) when is_map(params) do
    filters =
      for name <- TicketColumns.filter_names(), value = blank_to_nil(params[name]), do: %{"column" => name, "value" => split(name, value)}

    sort =
      case {blank_to_nil(params["sort"]), blank_to_nil(params["direction"])} do
        {nil, nil} -> nil
        {column, direction} -> %{"column" => column || @default_sort.column, "direction" => direction}
      end

    spec(%{"filters" => filters, "columns" => params |> Map.get("columns") |> blank_to_nil() |> split_list(), "sort" => sort})
  end

  @doc "A view as the API serves it: its times in ISO 8601."
  @spec payload(t()) :: map()
  def payload(view) do
    view
    |> Map.take([:id, :name, :filters, :columns, :sort])
    |> Map.merge(%{created_at: DateTime.to_iso8601(view.created_at), updated_at: DateTime.to_iso8601(view.updated_at)})
  end

  # -- The entity ------------------------------------------------------------------------------

  defp base(id, now) when id in [nil, ""], do: {:ok, %{id: new_id(), created_at: now}}

  defp base(id, _now) when is_binary(id) do
    with {:ok, view} <- get(id), do: {:ok, Map.take(view, [:id, :created_at])}
  end

  defp base(_id, _now), do: {:error, {:invalid, "id must be a string"}}

  defp new_id, do: "view-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, {:invalid, "name is required"}}
      name when byte_size(name) > @max_name -> {:error, {:invalid, "name is at most #{@max_name} bytes"}}
      name -> {:ok, name}
    end
  end

  defp name(_name), do: {:error, {:invalid, "name is required"}}

  # -- Filters ---------------------------------------------------------------------------------

  defp filters(nil), do: {:ok, []}

  defp filters(filters) when is_list(filters) do
    filters
    |> Enum.reduce_while({:ok, []}, fn filter, {:ok, acc} ->
      case filter(filter) do
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, filters} -> {:ok, Enum.reverse(filters)}
      error -> error
    end)
  end

  defp filters(_filters), do: {:error, {:invalid, "filters must be a list of {column, value}"}}

  defp filter(%{"column" => name} = filter) when is_binary(name) do
    if TicketColumns.filter(name),
      do: with({:ok, value} <- value(name, Map.get(filter, "value")), do: {:ok, %{column: name, value: value}}),
      else: {:error, {:invalid, "Unknown filter column: #{name}. The filters are: #{Enum.join(TicketColumns.filter_names(), ", ")}"}}
  end

  defp filter(_filter), do: {:error, {:invalid, "filters must be a list of {column, value}"}}

  defp value("since", value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, DateTime.to_iso8601(at)}
      {:error, _reason} -> {:error, {:invalid, "since must be an ISO 8601 time"}}
    end
  end

  defp value("since", _value), do: {:error, {:invalid, "since must be an ISO 8601 time"}}

  defp value(name, value) when not is_list(value), do: value(name, [value])
  defp value(name, []), do: {:error, {:invalid, "#{name} needs at least one value"}}
  defp value("priority", values), do: priorities(values)

  defp value(name, values) do
    values = Enum.map(values, &blank_to_nil/1)

    cond do
      Enum.any?(values, &is_nil/1) -> {:error, {:invalid, "#{name} values must be non-empty strings"}}
      name == "situation" -> situations(values)
      true -> {:ok, values}
    end
  end

  defp situations(values) do
    case Enum.reject(values, &(&1 in TicketColumns.situation_kinds())) do
      [] -> {:ok, values}
      unknown -> {:error, {:invalid, "Unknown situation(s): #{Enum.join(unknown, ", ")}. The situations are: #{Enum.join(TicketColumns.situation_kinds(), ", ")}"}}
    end
  end

  defp priorities(values) do
    values = Enum.map(values, &priority/1)

    if Enum.all?(values, &(&1 in @priorities)),
      do: {:ok, values},
      else: {:error, {:invalid, "priority values must be integers from 0 to 4"}}
  end

  defp priority(value) when is_integer(value), do: value

  defp priority(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {priority, ""} -> priority
      _invalid -> nil
    end
  end

  defp priority(_value), do: nil

  # -- Columns and sort ------------------------------------------------------------------------

  defp columns(nil), do: {:ok, @default_columns}
  defp columns([]), do: {:error, {:invalid, "columns must name at least one column"}}

  defp columns(columns) when is_list(columns) do
    if Enum.all?(columns, &is_binary/1) do
      case Enum.reject(columns, &TicketColumns.type/1) do
        [] -> {:ok, Enum.uniq(columns)}
        unknown -> unknown_columns(unknown)
      end
    else
      {:error, {:invalid, "columns must be a list of column names"}}
    end
  end

  defp columns(_columns), do: {:error, {:invalid, "columns must be a list of column names"}}

  defp sort(nil), do: {:ok, @default_sort}

  defp sort(%{} = sort) do
    column = Map.get(sort, "column") || @default_sort.column
    direction = Map.get(sort, "direction") || @default_sort.direction

    cond do
      not is_binary(column) or is_nil(TicketColumns.type(column)) -> unknown_columns([column], "Unknown sort column")
      direction not in ["asc", "desc"] -> {:error, {:invalid, "sort direction must be asc or desc"}}
      true -> {:ok, %{column: column, direction: direction}}
    end
  end

  defp sort(_sort), do: {:error, {:invalid, "sort must be {column, direction}"}}

  defp unknown_columns(unknown, label \\ "Unknown column(s)"),
    do: {:error, {:invalid, "#{label}: #{Enum.map_join(unknown, ", ", &to_string_safe/1)}. The columns are: #{Enum.join(TicketColumns.names(), ", ")}"}}

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)

  # -- Query strings ---------------------------------------------------------------------------

  defp split("since", value), do: value
  defp split(_name, value), do: split_list(value)

  defp split_list(nil), do: nil
  defp split_list(value), do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_to_nil(_value), do: nil
end
