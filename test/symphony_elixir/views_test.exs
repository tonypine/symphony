defmodule SymphonyElixir.ViewsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketColumns, Views}

  @now ~U[2026-11-10 04:00:00.000000Z]
  @later ~U[2026-11-10 05:00:00.000000Z]

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp invalid(params), do: params |> Views.save(now: @now) |> then(fn {:error, {:invalid, message}} -> message end)

  defp view(attrs \\ %{}), do: Map.merge(%{"name" => "Epic 6, waiting"}, attrs)

  test "creates a view with the defaults, and lists it" do
    assert {:ok, view} = Views.save(view(), now: @now)
    assert "view-" <> _hex = view.id
    assert %{name: "Epic 6, waiting", filters: [], columns: ~w(identifier title phase situation), created_at: @now, updated_at: @now} = view
    assert view.sort == %{column: "identifier", direction: "asc"}

    assert {:ok, [^view]} = Views.list()
    assert {:ok, ^view} = Views.get(view.id)
  end

  test "updates a view by id: a new name, filters, columns and sort, its creation time kept" do
    {:ok, created} = Views.save(view(), now: @now)

    attrs = %{
      "id" => created.id,
      "name" => "  Urgent bugs  ",
      "filters" => [%{"column" => "label", "value" => "bug"}, %{"column" => "priority", "value" => ["1", 2]}, %{"column" => "since", "value" => "2026-11-09T00:00:00Z"}],
      "columns" => ["identifier", "priority", "identifier"],
      "sort" => %{"column" => "priority", "direction" => "desc"}
    }

    assert {:ok, updated} = Views.save(attrs, now: @later)
    assert %{id: id, name: "Urgent bugs", created_at: @now, updated_at: @later, columns: ["identifier", "priority"]} = updated
    assert id == created.id

    assert updated.filters == [
             %{column: "label", value: ["bug"]},
             %{column: "priority", value: [1, 2]},
             %{column: "since", value: "2026-11-09T00:00:00Z"}
           ]

    assert updated.sort == %{column: "priority", direction: "desc"}
    assert {:ok, [^updated]} = Views.list()

    assert Views.payload(updated) == %{
             id: id,
             name: "Urgent bugs",
             filters: updated.filters,
             columns: ["identifier", "priority"],
             sort: updated.sort,
             created_at: "2026-11-10T04:00:00.000000Z",
             updated_at: "2026-11-10T05:00:00.000000Z"
           }
  end

  test "lists views by name, in any case" do
    {:ok, b} = Views.save(view(%{"name" => "beta"}), now: @now)
    {:ok, a} = Views.save(view(%{"name" => "Alpha"}), now: @later)
    assert {:ok, [^a, ^b]} = Views.list()
  end

  test "deletes a view; an id no view has is not found" do
    {:ok, view} = Views.save(view(), now: @now)

    assert :ok = Views.delete(view.id)
    assert {:ok, []} = Views.list()
    assert {:error, :not_found} = Views.delete(view.id)
    assert {:error, :not_found} = Views.get(view.id)
    assert {:error, :not_found} = Views.save(view(%{"id" => view.id}))
  end

  test "an unknown column is refused with the catalog's names" do
    message = invalid(view(%{"columns" => ["identifier", "colour"]}))
    assert message == "Unknown column(s): colour. The columns are: #{Enum.join(TicketColumns.names(), ", ")}"

    assert invalid(view(%{"sort" => %{"column" => "colour"}})) =~ "Unknown sort column: colour. The columns are: identifier, title"
    assert invalid(view(%{"sort" => %{"column" => 7}})) =~ "Unknown sort column: 7."
  end

  test "a refused filter names why" do
    assert invalid(view(%{"filters" => [%{"column" => "colour", "value" => "red"}]})) ==
             "Unknown filter column: colour. The filters are: repo, epic, phase, situation, label, priority, since"

    assert invalid(view(%{"filters" => [%{"column" => "situation", "value" => ["waiting_on_you", "asleep"]}]})) =~
             "Unknown situation(s): asleep. The situations are: waiting_on_you, retrying"

    assert invalid(view(%{"filters" => [%{"column" => "priority", "value" => [5]}]})) == "priority values must be integers from 0 to 4"
    assert invalid(view(%{"filters" => [%{"column" => "priority", "value" => "high"}]})) == "priority values must be integers from 0 to 4"
    assert invalid(view(%{"filters" => [%{"column" => "priority", "value" => [nil]}]})) == "priority values must be integers from 0 to 4"
    assert invalid(view(%{"filters" => [%{"column" => "since", "value" => "yesterday"}]})) == "since must be an ISO 8601 time"
    assert invalid(view(%{"filters" => [%{"column" => "since", "value" => [1]}]})) == "since must be an ISO 8601 time"
    assert invalid(view(%{"filters" => [%{"column" => "epic", "value" => []}]})) == "epic needs at least one value"
    assert invalid(view(%{"filters" => [%{"column" => "phase", "value" => ["Todo", " "]}]})) == "phase values must be non-empty strings"
    assert invalid(view(%{"filters" => [%{"value" => "x"}]})) == "filters must be a list of {column, value}"
    assert invalid(view(%{"filters" => %{"column" => "epic"}})) == "filters must be a list of {column, value}"
  end

  test "refuses a view without a name, and malformed columns, sort or id" do
    assert invalid(%{}) == "name is required"
    assert invalid(view(%{"name" => "  "})) == "name is required"
    assert invalid(view(%{"name" => String.duplicate("n", 121)})) == "name is at most 120 bytes"
    assert invalid(view(%{"columns" => []})) == "columns must name at least one column"
    assert invalid(view(%{"columns" => [1]})) == "columns must be a list of column names"
    assert invalid(view(%{"columns" => "title"})) == "columns must be a list of column names"
    assert invalid(view(%{"sort" => %{"direction" => "up"}})) == "sort direction must be asc or desc"
    assert invalid(view(%{"sort" => "title"})) == "sort must be {column, direction}"
    assert invalid(view(%{"id" => 5})) == "id must be a string"
    assert {:ok, []} = Views.list()
  end

  test "an inline query reads the same grammar from query parameters" do
    params = %{
      "epic" => "TP-1400",
      "situation" => "waiting_on_you, waiting_for_ci",
      "since" => "2026-11-09T00:00:00Z",
      "repo" => " ",
      "columns" => "identifier,situation",
      "sort" => "priority",
      "direction" => "desc",
      "view" => "ignored here"
    }

    assert {:ok, spec} = Views.query(params)

    assert spec == %{
             filters: [
               %{column: "epic", value: ["TP-1400"]},
               %{column: "situation", value: ["waiting_on_you", "waiting_for_ci"]},
               %{column: "since", value: "2026-11-09T00:00:00Z"}
             ],
             columns: ["identifier", "situation"],
             sort: %{column: "priority", direction: "desc"}
           }

    assert {:ok, %{filters: [], columns: ~w(identifier title phase situation), sort: %{column: "identifier", direction: "asc"}}} = Views.query(%{})
    assert {:ok, %{sort: %{column: "identifier", direction: "desc"}}} = Views.query(%{"direction" => "desc"})
    assert {:error, {:invalid, "Unknown column(s): colour." <> _}} = Views.query(%{"columns" => "colour"})
    assert {:error, {:invalid, "label needs at least one value"}} = Views.query(%{"label" => ","})
  end

  test "the store refuses a view without an id" do
    assert {:error, :invalid_view} = RunStore.put_view(%{name: "No id"})
  end
end
