defmodule SymphonyElixir.QaAgent.PlanFactsTest do
  # The facts of the app a macOS QA plan is handed (TP-1687), read from their sources.
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaAgent.PlanFacts
  alias SymphonyElixir.QaDriver.Pages

  setup do
    worktree = Path.join(System.tmp_dir!(), "plan-facts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf(worktree) end)
    %{worktree: worktree, fixtures: Path.join(worktree, "macos/Tests/Fixtures")}
  end

  defp write!(root, file, body \\ "{}") do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  test "a worktree with no fixtures says so", ctx do
    assert PlanFacts.fixtures(ctx.worktree) == "- Fixtures: this worktree holds no fixture directory under `macos/Tests/Fixtures`."
  end

  test "lists a directory of directories as one fixture per child, and any other directory as one, with their files", ctx do
    write!(ctx.fixtures, "director-app/home/api/v1/state.json")
    write!(ctx.fixtures, "director-app/home/api/v1/home.json")
    write!(ctx.fixtures, "director-app/home/config/symphony.yml")
    write!(ctx.fixtures, "director-app/home/.hidden")
    File.mkdir_p!(Path.join(ctx.fixtures, "director-app/empty"))
    write!(ctx.fixtures, "run-steps/events.json")
    write!(ctx.fixtures, "run-steps/artifacts/tr-1.ndjson")
    write!(ctx.fixtures, ".DS_Store")

    facts = PlanFacts.fixtures(ctx.worktree)

    assert facts =~ "such as `macos/Tests/Fixtures/director-app/empty`"
    assert facts =~ "\n  - director-app/empty: no files\n"
    assert facts =~ "\n  - director-app/home: api/v1/: home.json, state.json; config/: symphony.yml\n"
    assert facts =~ "\n  - run-steps: events.json; artifacts/: tr-1.ndjson"
    refute facts =~ "hidden"
    refute facts =~ "DS_Store"
  end

  test "names how many files it leaves out of a large fixture, and cuts the list to a bounded size", ctx do
    for n <- 1..45, do: write!(ctx.fixtures, "big/file-#{String.pad_leading(to_string(n), 2, "0")}.json")
    assert PlanFacts.fixtures(ctx.worktree) =~ "file-40.json; and 5 more"

    for state <- 1..200, do: write!(ctx.fixtures, "many/state-#{state}/api/v1/#{String.duplicate("x", 120)}.json")
    facts = PlanFacts.fixtures(ctx.worktree)
    assert String.ends_with?(facts, "\n  …")
    assert byte_size(facts) < 24_100
  end

  test "lists the pages the app opens on, and the ticket page" do
    assert PlanFacts.pages() =~ Pages.listing()
    assert PlanFacts.pages() =~ "a ticket's page, by its identifier"
  end

  test "lists the Gallery's entries and widths as its listing gives them, or why it has none" do
    listing = %{
      "entries" => [%{"id" => "button", "kind" => "component", "variations" => ["button-primary", "button-plain"]}, %{"id" => "home"}, "odd"],
      "widths" => %{"laptop" => 1440, "desktop" => 2560}
    }

    assert PlanFacts.gallery({:ok, listing}) ==
             "- The Component Gallery's entries, as the built app's gallery lists them (widths: desktop 2560 pt, laptop 1440 pt):\n" <>
               "  - button (component): button-primary, button-plain\n  - home\n  - \"odd\""

    assert PlanFacts.gallery({:ok, %{"entries" => []}}) == "- The Component Gallery: the built app's gallery lists no entry."
    assert PlanFacts.gallery({:error, {:qa_tool, "qa_no_build", "Run qa_build first."}}) =~ "(qa_no_build: Run qa_build first.)"
    assert PlanFacts.gallery({:error, :timeout}) =~ "could not be listed (:timeout)"

    many = %{"entries" => for(n <- 1..400, do: %{"id" => "entry-#{n}", "variations" => ["entry-#{n}-a"]})}
    assert byte_size(PlanFacts.gallery({:ok, many})) < 8_100
  end
end
