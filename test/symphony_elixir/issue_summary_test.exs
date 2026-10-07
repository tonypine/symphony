defmodule SymphonyElixir.IssueSummaryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IssueSummary

  @start "<!-- symphony:summary:start -->"
  @finish "<!-- symphony:summary:end -->"

  defp summary!(attrs \\ %{}) do
    {:ok, summary} = IssueSummary.new(Map.merge(%{"status" => "In progress", "changelog_entry" => "Started"}, attrs))
    summary
  end

  describe "new/1" do
    test "folds text onto one line and drops comment markers, so a field can't close the block" do
      assert {:ok, summary} =
               IssueSummary.new(%{
                 "status" => "  Waiting\non  review <!-- symphony:summary:end --> ",
                 "changelog_entry" => "Did\tthings",
                 "links" => %{
                   "review_brief" => " https://linear.app/acme/issue/TP-7#comment-1 ",
                   "artifacts" => [%{"label" => "[Domain] brief", "url" => "https://linear.app/acme/document/x"}, %{"label" => "PR", "url" => "http://github.com/a/b/pull/1"}]
                 }
               })

      assert summary == %{
               status: "Waiting on review symphony:summary:end",
               entry: "Did things",
               review_brief: "https://linear.app/acme/issue/TP-7#comment-1",
               artifacts: [%{label: "Domain brief", url: "https://linear.app/acme/document/x"}, %{label: "PR", url: "http://github.com/a/b/pull/1"}]
             }

      assert {:ok, %{review_brief: nil, artifacts: []}} = IssueSummary.new(%{"status" => "x", "changelog_entry" => "y", "links" => nil})
    end

    test "refuses invalid fields" do
      base = %{"status" => "x", "changelog_entry" => "y"}
      too_long = String.duplicate("a", 301)
      artifact = %{"label" => "PR", "url" => "https://github.com/a/b/pull/1"}

      for {attrs, error} <- [
            {%{"changelog_entry" => "y"}, :invalid_summary_status},
            {%{base | "status" => too_long}, :invalid_summary_status},
            {%{base | "status" => "<!---->"}, :invalid_summary_status},
            {%{base | "changelog_entry" => 3}, :invalid_summary_changelog_entry},
            {Map.put(base, "links", ["https://x.dev"]), :invalid_summary_links},
            {Map.put(base, "links", %{"review_brief" => "javascript:alert(1)"}), {:invalid_summary_url, "javascript:alert(1)"}},
            {Map.put(base, "links", %{"review_brief" => 7}), {:invalid_summary_url, nil}},
            {Map.put(base, "links", %{"artifacts" => "PR"}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => List.duplicate(artifact, 21)}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [artifact, %{"label" => "PR"}]}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [%{"label" => 1, "url" => "https://x.dev"}]}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [%{"label" => "[]", "url" => "https://x.dev"}]}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [%{"label" => "PR", "url" => "https://x.dev/a (b)"}]}), {:invalid_summary_url, "https://x.dev/a (b)"}}
          ] do
        assert IssueSummary.new(attrs) == {:error, error}
      end
    end
  end

  describe "put/3" do
    test "appends the block after a blank line, whatever the description ends with" do
      summary = summary!()

      for {description, prefix} <- [{nil, ""}, {"", ""}, {"Goal", "Goal\n\n"}, {"Goal\n", "Goal\n\n"}, {"Goal\n\n", "Goal\n\n"}] do
        assert {:ok, written} = IssueSummary.put(description, summary, ~D[2026-10-06])
        assert written == prefix <> rendered()
      end
    end

    test "renders the status, the review brief, the artifacts and the changelog" do
      summary = summary!(%{"links" => %{"review_brief" => "https://linear.app/b", "artifacts" => [%{"label" => "PR", "url" => "https://github.com/p"}]}})
      assert {:ok, written} = IssueSummary.put("Goal", summary, ~D[2026-10-06])

      assert written ==
               "Goal\n\n" <>
                 Enum.join(
                   [
                     @start,
                     "---",
                     "",
                     "### Symphony summary",
                     "",
                     "**Status:** In progress",
                     "",
                     "**Review brief:** [Review brief](https://linear.app/b)",
                     "",
                     "**Artifacts:**",
                     "",
                     "- [PR](https://github.com/p)",
                     "",
                     "**Changelog:**",
                     "",
                     "- 2026-10-06: Started",
                     @finish
                   ],
                   "\n"
                 )
    end

    test "replaces the block in place, prepending one entry and keeping the newest 20" do
      {:ok, description} = IssueSummary.put("Before", summary!(%{"changelog_entry" => "entry 0"}), ~D[2026-10-01])
      description = description <> "\nAfter"

      description =
        Enum.reduce(1..24, description, fn n, acc ->
          {:ok, acc} = IssueSummary.put(acc, summary!(%{"status" => "status #{n}", "changelog_entry" => "entry #{n}"}), ~D[2026-10-02])
          acc
        end)

      assert String.starts_with?(description, "Before\n\n" <> @start)
      assert String.ends_with?(description, @finish <> "\nAfter")
      assert description =~ "**Status:** status 24"
      refute description =~ "status 23"

      entries = Regex.scan(~r/^- 2026-10-0\d: (entry \d+)$/m, description, capture: :all_but_first) |> List.flatten()
      assert length(entries) == IssueSummary.changelog_cap()
      assert List.first(entries) == "entry 24"
      assert List.last(entries) == "entry 5"
    end

    test "starts a fresh changelog when the block has none, and refuses an unterminated block" do
      assert {:ok, written} = IssueSummary.put("A\n\n#{@start}\nold\n#{@finish}", summary!(), ~D[2026-10-06])
      assert written == "A\n\n" <> rendered()

      assert IssueSummary.put("A\n\n#{@start}\nold", summary!(), ~D[2026-10-06]) == {:error, :summary_block_unterminated}
    end
  end

  describe "strip/1" do
    test "removes the block and the blank lines around it" do
      assert IssueSummary.strip(nil) == nil
      assert IssueSummary.strip("No block") == "No block"
      assert IssueSummary.strip("Goal\n\n" <> rendered()) == "Goal"
      assert IssueSummary.strip("Goal\n\n" <> rendered() <> "\n\nMore\n") == "Goal\n\nMore\n"
      assert IssueSummary.strip(rendered() <> "\nMore") == "More"
      assert IssueSummary.strip(rendered()) == ""
      assert IssueSummary.strip("Goal\n\n#{IssueSummary.start_marker()}\nhalf") == "Goal"
      assert IssueSummary.end_marker() == @finish
    end
  end

  defp rendered do
    {:ok, block} = IssueSummary.put("", summary!(), ~D[2026-10-06])
    block
  end
end
