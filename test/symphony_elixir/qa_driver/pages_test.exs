defmodule SymphonyElixir.QaDriver.PagesTest do
  # The pages of Symphony.app's window `qa_launch_app` opens the app on (TP-1664).
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaDriver.Pages

  @window_swift Path.expand("../../../macos/Sources/SymphonyBarCore/SymphonyWindow.swift", __DIR__)

  # The app's `SymphonyView` cases, in order, each with its title, read from the Swift source.
  defp swift_pages do
    source = File.read!(@window_swift)
    [_all, cases] = Regex.run(~r/public enum SymphonyView[^{]*\{.*?\n    case ([a-z, ]+)\n/s, source)
    [_all, titles] = Regex.run(~r/public var title: String \{\n        switch self \{\n(.*?)\n        \}/s, source)
    titles = Map.new(Regex.scan(~r/case \.(\w+): "([^"]+)"/, titles), fn [_line, name, title] -> {name, title} end)
    for name <- String.split(cases, ", "), do: %{name: name, title: Map.fetch!(titles, name)}
  end

  test "lists every page of the app's window, by name and title, in sidebar order" do
    assert Pages.all() == swift_pages()
    assert length(Pages.all()) == 15
  end

  test "names a page by its name or title, whatever the case" do
    assert Pages.named("overview") == {:ok, %{name: "overview", title: "Home"}}
    assert Pages.named(" HOME\n") == {:ok, %{name: "overview", title: "Home"}}
    assert Pages.named("Tickets") == {:ok, %{name: "tickets", title: "Tickets"}}
    assert Pages.named("the Home page") == :error
    assert Pages.named("") == :error
    assert Pages.listing() =~ "`inbox` (Inbox), `overview` (Home), `journal` (Journal)"
  end

  test "places a plan's free-text page: a ticket's page, a page of the window, or unknown" do
    assert Pages.place("Tickets") == {:page, %{name: "tickets", title: "Tickets"}}
    assert Pages.place("the Home page") == {:page, %{name: "overview", title: "Home"}}
    assert Pages.place("Quality tab") == {:page, %{name: "quality", title: "Quality"}}
    assert Pages.place("TP-1609's page") == {:ticket, "TP-1609"}
    assert Pages.place("the ticket page of tp-7") == {:ticket, "TP-7"}
    assert Pages.place("The board of cards") == :unknown
    assert Pages.place(nil) == :unknown
  end

  test "knows a ticket identifier" do
    assert Pages.ticket?("TP-12")
    assert Pages.ticket?("tp-12")
    refute Pages.ticket?("TP-12 page")
    refute Pages.ticket?("Tickets")
    refute Pages.ticket?(12)
  end
end
