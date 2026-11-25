defmodule SymphonyElixir.QaAgent.PlanFacts do
  @moduledoc """
  The facts of the app a stepped macOS QA pass hands its plan session (TP-1687), each read from its
  one source when the prompt is built, so the plan never searches the code for them:

  - `fixtures/1`: the committed fixture directories under `macos/Tests/Fixtures` in the pass's
    worktree and the files each holds, read from the directories themselves: a directory that holds
    only directories (`director-app`) is a set of fixtures, one per child; any other is one fixture;
  - `pages/0`: the pages `qa_launch_app` opens the app on, from `SymphonyElixir.QaDriver.Pages`;
  - `gallery/1`: the Component Gallery's entries and widths, as the built app's gallery lists them
    (`qa_gallery` with no entry, `SymphonyElixir.QaDriver.Gallery.listing/2`).

  The element names are the `macos_app` playbook's "QA names" section, which the plan reads with its
  screen rules (`SymphonyElixir.QaAgent.StepPrompts.screen_rules/1`) and which a Swift test holds to
  the app's own scheme (`QAElementNames.scheme`, the `names` `qa_elements` reports).

  Each fact is cut to a bounded size.
  """

  alias SymphonyElixir.QaDriver.Pages

  @fixtures_root "macos/Tests/Fixtures"
  @fixtures_bytes 24_000
  @gallery_bytes 8_000
  @files_per_fixture 40

  @doc "The fixture directories under `macos/Tests/Fixtures` in `worktree`, with the files each holds."
  @spec fixtures(Path.t()) :: String.t()
  def fixtures(worktree) when is_binary(worktree) do
    root = Path.join(worktree, @fixtures_root)

    case root |> subdirs() |> Enum.flat_map(&fixture_dirs(root, &1)) do
      [] ->
        "- Fixtures: this worktree holds no fixture directory under `#{@fixtures_root}`."

      dirs ->
        lines = Enum.map_join(dirs, "\n", &fixture_line(root, &1))

        cut(
          "- Fixtures (`api_fixtures`: the directory by its path in the checkout, such as `#{@fixtures_root}/#{hd(dirs)}`; " <>
            "a state fixture by its name alone), each with the files it holds, read from this worktree:\n" <> lines,
          @fixtures_bytes
        )
    end
  end

  @doc "The pages the app opens on at launch, and the ticket page."
  @spec pages() :: String.t()
  def pages do
    "- Pages the app opens on at launch (a brief's `page`): " <>
      Pages.listing() <>
      "; and a ticket's page, by its identifier (`TP-12's page`), for a ticket the fixture holds."
  end

  @doc """
  The Component Gallery's entries and widths, from what `qa_gallery` with no entry answered
  (`{:ok, listing}`), or why it could not list them.
  """
  @spec gallery({:ok, map()} | {:error, term()}) :: String.t()
  def gallery({:ok, %{"entries" => [_ | _] = entries} = listing}) do
    widths = listing |> Map.get("widths", %{}) |> Enum.sort() |> Enum.map_join(", ", fn {name, width} -> "#{name} #{width} pt" end)

    cut(
      "- The Component Gallery's entries, as the built app's gallery lists them (widths: #{widths}):\n" <>
        Enum.map_join(entries, "\n", &entry_line/1),
      @gallery_bytes
    )
  end

  def gallery({:ok, _listing}), do: "- The Component Gallery: the built app's gallery lists no entry."

  def gallery({:error, {:qa_tool, code, message}}), do: "- The Component Gallery: its entries could not be listed (#{code}: #{message})."
  def gallery({:error, reason}), do: "- The Component Gallery: its entries could not be listed (#{inspect(reason)})."

  defp entry_line(%{"id" => id} = entry) do
    kind = if is_binary(entry["kind"]), do: " (#{entry["kind"]})", else: ""

    case List.wrap(entry["variations"]) do
      [] -> "  - #{id}#{kind}"
      variations -> "  - #{id}#{kind}: #{Enum.join(variations, ", ")}"
    end
  end

  defp entry_line(entry), do: "  - #{inspect(entry)}"

  # A directory holding only directories is a set of fixtures, one per child; any other is one.
  defp fixture_dirs(root, name) do
    case {subdirs(Path.join(root, name)), files_in(Path.join(root, name))} do
      {[_ | _] = children, []} -> Enum.map(children, &Path.join(name, &1))
      _one -> [name]
    end
  end

  defp fixture_line(root, dir) do
    files = root |> Path.join(dir) |> all_files()
    {shown, rest} = Enum.split(files, @files_per_fixture)
    more = if rest == [], do: "", else: "; and #{length(rest)} more"
    "  - #{dir}: #{grouped(shown)}#{more}"
  end

  # The files by their folder: `api/v1/: home.json, state.json; config/: symphony.yml`.
  defp grouped([]), do: "no files"

  defp grouped(files) do
    files
    |> Enum.group_by(&Path.dirname/1, &Path.basename/1)
    |> Enum.sort()
    |> Enum.map_join("; ", fn
      {".", names} -> Enum.join(names, ", ")
      {folder, names} -> "#{folder}/: #{Enum.join(names, ", ")}"
    end)
  end

  defp all_files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  defp subdirs(dir), do: dir |> list() |> Enum.filter(&File.dir?(Path.join(dir, &1)))
  defp files_in(dir), do: dir |> list() |> Enum.reject(&File.dir?(Path.join(dir, &1)))

  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp cut(text, bytes) when byte_size(text) > bytes, do: String.slice(text, 0, bytes) <> "\n  …"
  defp cut(text, _bytes), do: text
end
