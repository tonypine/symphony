defmodule SymphonyElixir.QaPreCheck do
  @moduledoc """
  The walkthrough steps and plan checks a named automated test proves, as a QA pass hands them on
  (ADR 0003, `docs/adr/0003-automated-tests-first-qa-last-resort.md`), and the lookup that finds
  the named test in a checkout.

  A test proof is complete once it is recorded: the run executed the test when it wrote it, a proof
  naming a test Symphony cannot find is refused when it is recorded (`missing_test/3`, run by
  `SymphonyElixir.AgentTools.TicketLedger`), and CI runs the test on the pull request and gates the
  merge. So a QA pass neither reads nor waits for CI on a proof's account: each step a recorded
  test proves reaches the QA agent as proved, named with its test, and QA does not walk it. Each is
  one line of the report's `### Pre-checks` (`report_checks/1`), naming the step and its test.

  The lookup: each path part of a test (a file or folder, with or without a `:line` suffix) is a
  tracked file, and each other part (a scenario or test name) is found in the tracked files, within
  the file a path part before it names. A path part ends at ` › `, `: ` or a space
  (`file: name`, `file › name`, `file name`); a part that opens with a file the name is not in is
  also read as one name, so a test named `WORKFLOW.md front matter …` is found. A name is found as
  text (a test name or a describe alone) or as ExUnit's full test name, the describe and the test
  joined by a space, as `mix test` prints it, or as a Swift test's class plus method
  (`Class method`, `Class.method` or `Class/method`, as XCTest prints it), found when one tracked
  `.swift` file declares both the type (`class`, `struct`, `extension`, `enum` or `actor`) and the
  `func`.
  """

  alias SymphonyElixir.GitConfigCommands
  alias SymphonyElixir.Walkthrough

  @separator ~r/\s*(?:›|\s>\s)\s*/u
  @path_part ~r{^[\w.@+/-]+$}u
  @line_suffix ~r/(?::\d+)+$/
  @path_then_name ~r/^([\w.@+\/-]+(?::\d+)*)(?::\s+|\s+)(\S.*)$/u
  @file_path ~r{/.*\.\w+$}u
  @path_like ~r{/|\.\w+$}u
  @declaration_grep ~S{^[[:space:]]*(describe|test)[[:space:]]+"}
  @test_declaration ~r/^(\s*)(describe|test)\s+"((?:[^"\\]|\\.)*)"/u
  @mix_test_suffix ~r/(?:\s+\([A-Z][\w.]*\)|\s+\(\d+(?:\.\d+)?ms\)|\s+\[L#\d+\])+$/
  @quoted ~r/^"(.*)"$|^“(.*)”$/su
  @swift_test ~r/^([A-Za-z_]\w*)(?:\s+|\.|\/)([A-Za-z_]\w*)(?:\(\))?$/u
  @tried_forms "tried as a describe plus a test name, a test name, a describe name and a Swift class plus method"

  @doc """
  The test names a proof may give, as a refusal of one names them.
  """
  @spec test_name_forms() :: String.t()
  def test_name_forms,
    do:
      "a file path plus the test name (`test/x_test.exs: the test`), a describe plus a test name as `mix test` prints it, " <>
        "or a Swift class plus method (`TimelineKeysTests testItWorks`)"

  @doc """
  The steps of `steps` a recorded test proves, in their order: proved as recorded, with nothing
  read from CI or the checkout.
  """
  @spec proved([Walkthrough.step()]) :: [Walkthrough.step()]
  def proved(steps) when is_list(steps), do: Enum.filter(steps, &Walkthrough.named_test?/1)

  @doc """
  What the checkout at `workspace` lacks of the named `test`, or nil when every part of it is
  there (or there is no test). A path part narrows the search of the name parts after it. This is
  the lookup the ticket ledger runs when a proof is recorded (`SymphonyElixir.AgentTools.TicketLedger`).
  `opts[:git]` runs git (`fn args, dir -> {output, status} end`).
  """
  @spec missing_test(String.t() | nil, Path.t(), keyword()) :: String.t() | nil
  def missing_test(test, workspace, opts \\ []) do
    if is_binary(test), do: find_test(test, workspace, Keyword.get(opts, :git, &git/2))
  end

  defp find_test(test, workspace, git) do
    files = tracked_files(git, workspace)

    test
    |> String.split(@separator, trim: true)
    |> Enum.reject(&(unquote_part(&1) == ""))
    |> find_parts(nil, &find_reading(&1, &2, files, git, workspace))
    |> case do
      {:missing, missing} -> missing
      {:ok, _scope} -> nil
    end
  end

  # Each part found in turn, the scope a path part narrows to carried to the next one.
  defp find_parts(parts, scope, find) do
    Enum.reduce_while(parts, {:ok, scope}, fn part, {:ok, scope} ->
      case find.(part, scope) do
        {:ok, scope} -> {:cont, {:ok, scope}}
        missing -> {:halt, missing}
      end
    end)
  end

  # A part that opens with a path is read first as the file and a name in it, then, when that
  # misses, as one name, since a test's own name may open with a file
  # (`symphony.yml is required before …`). When both miss, the first reading's detail names the file.
  defp find_reading(part, scope, files, git, workspace) do
    find = &find_part(&1, &2, files, git, workspace)

    case split_path(unquote_part(part), files) do
      [_whole] ->
        find.(part, scope)

      path_and_name ->
        with {:missing, missing} <- find_parts(path_and_name, scope, find),
             {:missing, _whole} <- find.(part, scope) do
          {:missing, missing}
        end
    end
  end

  # A part that opens with a path and goes on with a name (`file: name`, `file name`), as an
  # implementer copies a test from its file, may be two parts. The path is a path to a file
  # (`test/x_test.exs`), or a tracked folder with a `/` (`.github/workflows`) or file name
  # (`x_test.exs`), so a name such as `Walkthrough.steps parses`, `a/b input` or one opening with a
  # folder's bare name (`docs are current`) stays whole.
  defp split_path(part, files) do
    with [_part, path, name] <- Regex.run(@path_then_name, part),
         bare = String.replace(path, @line_suffix, ""),
         true <- Regex.match?(@file_path, bare) or (Regex.match?(@path_like, bare) and Enum.any?(files, &path_match?(&1, bare))) do
      [path, name]
    else
      _no_path -> [part]
    end
  end

  # A part is read without the quotes around it first (`"name"`), then, when that misses, as it is
  # written, since a test's own name may open and close with a quote (`"Run" runs it, "Stop" stops "it"`).
  # A path is never read again with its quotes: it is a tracked file or missing, never searched text.
  defp find_part(part, scope, files, git, workspace) do
    find = &find_text(&1, scope, files, git, workspace)
    part = String.trim(part)
    unquoted = unquote_part(part)
    retry? = unquoted != part and not Regex.match?(@path_part, String.replace(unquoted, @line_suffix, ""))

    case find.(unquoted) do
      {:missing, _detail} = missing when retry? ->
        with {:missing, _original} <- find.(part), do: missing

      found ->
        found
    end
  end

  # A path-like part with a `/` must be tracked. A bare file name (`check_test.exs`) is matched as a
  # path first, and otherwise searched for like any name, since `Walkthrough.steps` looks like one
  # too. A name with spaces (`handles a/b input`) is never a path, whatever it holds.
  defp find_text(part, scope, files, git, workspace) do
    path = String.replace(part, @line_suffix, "")
    path? = Regex.match?(@path_part, path)
    matched = if path?, do: Enum.filter(files, &path_match?(&1, path)), else: []

    swift? = fn -> swift_test_found?(git, workspace, part, scope) end

    cond do
      matched != [] -> {:ok, {path, matched}}
      path? and String.contains?(path, "/") -> if swift?.(), do: {:ok, scope}, else: {:missing, "#{code(part)} is not in the checkout"}
      name_found?(git, workspace, part, scope) or swift?.() -> {:ok, scope}
      true -> {:missing, "#{code(part)} is not in #{scope_name(scope)} (#{@tried_forms})"}
    end
  end

  # A Swift test named as its class plus method (`TimelineKeysTests testIt`, `.` or `/` between
  # them, `()` after), as XCTest prints it: the type and the `func` are declared on different lines,
  # so a search of the whole name misses it. Found when one tracked `.swift` file in the scope
  # declares both, not merely each somewhere in the checkout.
  defp swift_test_found?(git, workspace, part, scope) do
    with [_part, type, method] <- Regex.run(@swift_test, part),
         [_ | _] = swift <- swift_files(scope) do
      declaring = &declaring_files(git, workspace, &1, swift)
      types = declaring.("(class|struct|extension|enum|actor)[[:space:]]+#{type}")
      types != [] and Enum.any?(declaring.("func[[:space:]]+#{method}"), &(&1 in types))
    else
      _no_swift_test -> false
    end
  end

  defp swift_files(nil), do: ["*.swift"]
  defp swift_files({_path, files}), do: Enum.filter(files, &String.ends_with?(&1, ".swift"))

  # The files of `swift` that declare `pattern` followed by a character no identifier holds.
  defp declaring_files(git, workspace, pattern, swift) do
    case git.(["grep", "-l", "-I", "-E", "-e", pattern <> "([^[:alnum:]_]|$)", "--" | swift], workspace) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _none -> []
    end
  end

  defp scope_name(nil), do: "the checkout"
  defp scope_name({path, _files}), do: code(path)

  # The file itself, or a file under the folder, from the checkout's root or below it.
  defp path_match?(file, path) do
    path = String.trim_trailing(path, "/")

    file == path or String.ends_with?(file, "/" <> path) or String.starts_with?(file, path <> "/") or
      String.contains?(file, "/" <> path <> "/")
  end

  # A name is found the way a person reading the tests finds it: as text in the files (a test name
  # alone, a describe alone, a scenario name), or as ExUnit's full test name, the describe and the
  # test joined by a space, which never sit on one line. A name copied from `mix test`'s output
  # (`test <describe> <test> (Module)`, or with `--trace`'s `(2.1ms) [L#12]`) is the full name too.
  defp name_found?(git, workspace, name, scope) do
    grep?(git, workspace, name, scope) or
      Enum.any?(full_test_names(git, workspace, scope), &(&1 in [name, from_mix_test(name)]))
  end

  defp grep?(git, workspace, text, scope) do
    match?({_output, 0}, git.(["grep", "-q", "-I", "-F", "-e", text, "--" | scope_files(scope)], workspace))
  end

  # ExUnit's full name of each test in the scope: its describe's name, a space and its own name. A
  # test belongs to the last describe indented less than it; one outside a describe is its name. A
  # test in a describe is listed by its own name too, unescaped, since the file escapes its quotes
  # (`answering \"Run it again\"`) and a search of the text misses it.
  defp full_test_names(git, workspace, scope) do
    case git.(["grep", "-n", "-I", "--null", "-E", "-e", @declaration_grep, "--" | scope_files(scope)], workspace) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&test_line/1)
        |> Enum.chunk_by(&elem(&1, 0))
        |> Enum.flat_map(&file_test_names/1)

      _none ->
        []
    end
  end

  # A matched line's file, indentation, kind and name; none when its name is not one quoted string
  # on the line, such as a name that spans lines.
  defp test_line(line) do
    [file, _number, content] = String.split(line, <<0>>, parts: 3)

    case Regex.run(@test_declaration, content) do
      [_content, indent, kind, name] -> [{file, String.length(indent), kind, String.replace(name, ~S(\"), ~S("))}]
      nil -> []
    end
  end

  defp file_test_names(lines) do
    lines
    |> Enum.reduce({nil, []}, fn
      {_file, indent, "describe", name}, {_describe, names} ->
        {{indent, name}, [name | names]}

      {_file, indent, "test", name}, {{outer, describe}, names} when indent > outer ->
        {{outer, describe}, ["#{describe} #{name}", name | names]}

      {_file, _indent, "test", name}, {describe, names} ->
        {describe, [name | names]}
    end)
    |> elem(1)
  end

  defp from_mix_test(name), do: name |> String.replace(~r/^test\s+/, "") |> String.replace(@mix_test_suffix, "")

  defp scope_files(nil), do: []
  defp scope_files({_path, files}), do: files

  defp tracked_files(git, workspace) do
    case git.(["ls-files", "-z"], workspace) do
      {output, 0} -> String.split(output, <<0>>, trim: true)
      _failed -> []
    end
  end

  defp git(args, workspace), do: System.cmd("git", GitConfigCommands.subcommand_args(args), cd: workspace, stderr_to_stdout: true)

  @doc """
  The lines of the QA report's `### Pre-checks` (`SymphonyElixir.QaAgent.Report`), one per step a
  recorded test proves: the step, `proved` and its test. No line reads CI.
  """
  @spec report_checks([Walkthrough.step()]) :: [%{name: String.t(), status: :proved, detail: String.t()}]
  def report_checks(steps) do
    for %{proof: %{by: :test, test: test}} = step <- steps do
      %{name: "step #{step.number}", status: :proved, detail: "proved by #{code(test)}, recorded on the ticket"}
    end
  end

  # The text inside one pair of quotes around the whole part (`"name"`, `“name”`), or the part as it
  # is: a name that only ends in a quoted phrase (`answering "Run it again"`) keeps its quotes.
  defp unquote_part(part) do
    part = String.trim(part)

    case Regex.run(@quoted, part, capture: :all_but_first) do
      nil -> part
      inner -> inner |> Enum.join() |> String.trim()
    end
  end

  defp code(text), do: "`#{text}`"
end
