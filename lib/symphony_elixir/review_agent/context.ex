defmodule SymphonyElixir.ReviewAgent.Context do
  @moduledoc """
  Builds structured source material for the reviewer-agent gate.
  """

  require Logger

  alias SymphonyElixir.{AgentLabels, PromptSafety}
  alias SymphonyElixir.Linear.Issue

  @context_radius 6
  @max_adjacent_windows 24
  @max_call_sites_per_symbol 5
  @max_symbols 12
  @per_file_min 12
  @per_file_max 160
  @max_evidence_file_bytes 200_000
  @lock_files ~w[
    Cargo.lock
    Gemfile.lock
    composer.lock
    mix.lock
    package-lock.json
    pnpm-lock.yaml
    poetry.lock
    yarn.lock
  ]

  @type git_fun :: (list(String.t()) -> {:ok, String.t()} | {:error, term()})
  @type line_range :: {pos_integer(), pos_integer()}
  @typep evidence_source :: :diff | :file | :adjacent_context
  @typep evidence_lookup :: %{
           path: String.t(),
           line_range: line_range(),
           text: String.t(),
           source: evidence_source()
         }

  @spec build(Issue.t(), Path.t(), String.t(), keyword(), git_fun()) ::
          {:ok, map()} | {:error, term()}
  def build(%Issue{} = issue, workspace, git_range, opts, git_fun)
      when is_binary(workspace) and is_binary(git_range) and is_function(git_fun, 1) do
    with {:ok, diff} <- git_fun.(["diff", git_range]),
         {:ok, name_status} <- git_fun.(["diff", "--name-status", git_range]),
         {:ok, stat} <- git_fun.(["diff", "--stat", git_range]),
         {:ok, numstat} <- git_fun.(["diff", "--numstat", git_range]),
         {:ok, zero_context_diff} <- git_fun.(["diff", "--unified=0", git_range]),
         {:ok, commit_messages} <- git_fun.(["log", "--reverse", "--format=%s%n%b%x1e", git_range]) do
      raw_acceptance_criteria = acceptance_criteria(issue.description)
      acceptance_items = acceptance_criteria_items(raw_acceptance_criteria)
      inventory = changed_file_inventory(name_status, numstat, diff, zero_context_diff)
      changed_paths = Enum.map(inventory, & &1.path)
      workpad = workpad_evidence(issue.comments)
      reviewer_comments = reviewer_comments(Keyword.get(opts, :reviewer_comments, []))
      ci_failure = ci_failure(Keyword.get(opts, :ci_failure))
      sanitized_acceptance = present_linear(raw_acceptance_criteria, &PromptSafety.linear_issue_acceptance_criteria/1)

      adjacent_context =
        adjacent_context(workspace, inventory, git_fun,
          worker_host: Keyword.get(opts, :worker_host),
          changed_paths: changed_paths
        )

      context_pack = %{
        issue: %{
          title: present_linear(issue.title, &PromptSafety.linear_issue_title/1),
          description: present_linear(issue.description, &PromptSafety.linear_issue_body/1),
          acceptance_criteria: sanitized_acceptance,
          acceptance_criteria_items: acceptance_items,
          acceptance_matrix: Enum.map(acceptance_items, &%{criterion: &1, evidence: [], missing_evidence: true})
        },
        git: %{
          range: git_range,
          stat: String.trim(stat),
          commit_messages: String.trim(commit_messages)
        },
        changed_files: inventory,
        adjacent_context: adjacent_context,
        validation_evidence: workpad,
        reviewer_comments: reviewer_comments,
        ci_failure: ci_failure
      }

      rendered = render(context_pack)
      coverage = coverage_metadata(context_pack, rendered)
      warnings = linear_input_warnings(issue, raw_acceptance_criteria, workpad, reviewer_comments, ci_failure)

      if coverage.summarized_files != [] or coverage.generated_lock_files != [] do
        summary =
          "full=#{length(coverage.fully_reviewed_files)} " <>
            "summarized=#{length(coverage.summarized_files)} " <>
            "generated_lock=#{length(coverage.generated_lock_files)}"

        Logger.info("ReviewAgent context summarized issue=#{issue.identifier || issue.id} #{summary}")
      end

      {:ok,
       %{
         issue_title: context_pack.issue.title,
         issue_description: context_pack.issue.description,
         acceptance_criteria: context_pack.issue.acceptance_criteria,
         acceptance_criteria_items: acceptance_items,
         linear_input_warnings: warnings,
         changed_paths: changed_paths,
         changed_file_inventory: inventory,
         commit_messages: String.trim(commit_messages),
         git_range: git_range,
         diff: rendered.text,
         diff_line_count: count_lines(diff),
         diff_truncated?: summarized?(coverage),
         review_coverage: coverage,
         file_contents: evidence_file_contents(inventory, git_fun),
         context_pack: context_pack
       }}
    end
  end

  @doc """
  Returns every evidence source for a cited file: the cited range from each of the
  diff, the full file and the adjacent windows, plus the file's numbered lines merged
  from all three so a quote can be found outside the cited range.
  """
  @spec grounding_evidence(map(), String.t(), line_range()) ::
          {:ok, %{path: String.t(), cited: [evidence_lookup()], lines: [{pos_integer(), String.t()}]}}
          | {:error, term()}
  def grounding_evidence(source, path, {start_line, end_line})
      when is_map(source) and is_binary(path) and is_integer(start_line) and is_integer(end_line) and start_line > 0 and
             end_line >= start_line do
    with {:ok, normalized_path} <- normalize_lookup_path(path),
         :ok <- path_known_to_context?(source, normalized_path) do
      cited =
        [
          diff_evidence(source, normalized_path, start_line, end_line),
          file_evidence(source, normalized_path, start_line, end_line),
          adjacent_evidence(source, normalized_path, start_line, end_line)
        ]
        |> Enum.flat_map(fn
          {:ok, evidence} -> [evidence]
          nil -> []
        end)

      {:ok, %{path: normalized_path, cited: cited, lines: numbered_lines(source, normalized_path)}}
    end
  end

  def grounding_evidence(_source, _path, _line_range), do: {:error, :invalid_line_range}

  defp numbered_lines(source, path) do
    [
      numbered_file_lines(source, path),
      numbered_patch_lines(source, path),
      numbered_adjacent_lines(source, path)
    ]
    |> List.flatten()
    |> Enum.reduce(%{}, fn {number, text}, acc -> Map.put_new(acc, number, text) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp numbered_file_lines(source, path) do
    case source |> Map.get(:file_contents, %{}) |> Map.get(path) do
      contents when is_binary(contents) ->
        contents
        |> String.split("\n", trim: false)
        |> Enum.with_index(1)
        |> Enum.map(fn {text, number} -> {number, text} end)

      _contents ->
        []
    end
  end

  defp numbered_patch_lines(source, path) do
    case Enum.find(Map.get(source, :changed_file_inventory, []), &(Map.get(&1, :path) == path)) do
      %{patch: patch} when is_binary(patch) -> patch_numbered_lines(patch)
      _file -> []
    end
  end

  defp numbered_adjacent_lines(source, path) do
    case get_in(source, [:context_pack, :adjacent_context, :windows]) do
      windows when is_list(windows) ->
        windows
        |> Enum.filter(&(Map.get(&1, :path) == path and is_binary(Map.get(&1, :text))))
        |> Enum.flat_map(&String.split(&1.text, "\n", trim: false))
        |> Enum.flat_map(&adjacent_numbered_line/1)

      _other ->
        []
    end
  end

  defp normalize_lookup_path(path) do
    case String.trim(path) do
      "" -> {:error, :invalid_file}
      "/" <> _rest -> {:error, :absolute_file_not_allowed}
      normalized -> {:ok, normalized}
    end
  end

  defp path_known_to_context?(source, path) do
    if path in changed_paths(source) or path in adjacent_paths(source) do
      :ok
    else
      {:error, {:file_not_in_review_context, path}}
    end
  end

  defp changed_paths(source) do
    source
    |> Map.get(:changed_paths, [])
    |> Enum.filter(&is_binary/1)
  end

  defp adjacent_paths(source) do
    source
    |> get_in([:context_pack, :adjacent_context, :windows])
    |> case do
      windows when is_list(windows) -> windows |> Enum.map(&Map.get(&1, :path)) |> Enum.filter(&is_binary/1)
      _other -> []
    end
  end

  defp diff_evidence(source, path, start_line, end_line) do
    source
    |> Map.get(:changed_file_inventory, [])
    |> Enum.find(&(Map.get(&1, :path) == path))
    |> case do
      nil ->
        nil

      %{patch: patch} when is_binary(patch) ->
        case complete_patch_lines_in_range(patch, start_line, end_line) do
          [] -> nil
          lines -> {:ok, %{path: path, line_range: {start_line, end_line}, text: Enum.join(lines, "\n"), source: :diff}}
        end

      _file ->
        nil
    end
  end

  defp file_evidence(source, path, start_line, end_line) do
    source
    |> Map.get(:file_contents, %{})
    |> Map.get(path)
    |> case do
      contents when is_binary(contents) ->
        case file_lines_in_range(contents, start_line, end_line) do
          [] -> nil
          lines -> {:ok, %{path: path, line_range: {start_line, end_line}, text: Enum.join(lines, "\n"), source: :file}}
        end

      _contents ->
        nil
    end
  end

  defp adjacent_evidence(source, path, start_line, end_line) do
    source
    |> get_in([:context_pack, :adjacent_context, :windows])
    |> case do
      windows when is_list(windows) ->
        Enum.find_value(windows, &adjacent_window_evidence(&1, path, start_line, end_line))

      _other ->
        nil
    end
  end

  defp adjacent_window_evidence(
         %{path: window_path, start_line: window_start, end_line: window_end, text: text},
         path,
         start_line,
         end_line
       )
       when window_path == path and is_integer(window_start) and is_integer(window_end) and is_binary(text) do
    if start_line >= window_start and end_line <= window_end do
      build_adjacent_evidence(path, text, start_line, end_line)
    end
  end

  defp adjacent_window_evidence(_window, _path, _start_line, _end_line), do: nil

  defp build_adjacent_evidence(path, text, start_line, end_line) do
    case adjacent_lines_in_range(text, start_line, end_line) do
      [] ->
        nil

      lines ->
        {:ok, %{path: path, line_range: {start_line, end_line}, text: Enum.join(lines, "\n"), source: :adjacent_context}}
    end
  end

  defp complete_patch_lines_in_range(patch, start_line, end_line) do
    lines = patch_lines_in_range(patch, start_line, end_line)
    expected_count = end_line - start_line + 1

    if length(lines) == expected_count do
      lines
    else
      []
    end
  end

  defp patch_lines_in_range(patch, start_line, end_line) do
    patch
    |> patch_numbered_lines()
    |> Enum.flat_map(fn {number, text} -> if number >= start_line and number <= end_line, do: [text], else: [] end)
  end

  defp patch_numbered_lines(patch) do
    patch
    |> String.split("\n", trim: false)
    |> Enum.reduce({nil, []}, fn line, {next_line, acc} ->
      cond do
        hunk = Regex.run(~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line, capture: :all_but_first) ->
          [start] = hunk
          {parse_int(start), acc}

        is_nil(next_line) ->
          {next_line, acc}

        String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
          {next_line + 1, [{next_line, String.slice(line, 1..-1//1)} | acc]}

        String.starts_with?(line, " ") ->
          {next_line + 1, [{next_line, String.slice(line, 1..-1//1)} | acc]}

        true ->
          {next_line, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp adjacent_lines_in_range(text, start_line, end_line) do
    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&adjacent_numbered_line/1)
    |> Enum.flat_map(fn {number, line} -> if number >= start_line and number <= end_line, do: [line], else: [] end)
  end

  defp file_lines_in_range(contents, start_line, end_line) do
    contents
    |> String.split("\n", trim: false)
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> case do
      lines when length(lines) == end_line - start_line + 1 -> lines
      _lines -> []
    end
  end

  defp adjacent_numbered_line(line) do
    case Regex.run(~r/^(\d+): ?(.*)$/, line, capture: :all_but_first) do
      [number, text] -> [{parse_int(number), text}]
      _no_line_number -> []
    end
  end

  defp changed_file_inventory(name_status, numstat, diff, zero_context_diff) do
    stats = parse_numstat(numstat)
    patches = file_patches(diff)
    hunk_headers = hunk_headers_by_path(zero_context_diff)

    name_status
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [status | paths] = String.split(line, "\t", trim: true)
      path = List.last(paths) || ""
      patch = Map.get(patches, path, "")
      stat = Map.get(stats, path, %{additions: nil, deletions: nil, binary?: false})
      classification = classify_path(path, stat.binary?)

      %{
        path: path,
        status: status,
        additions: stat.additions,
        deletions: stat.deletions,
        binary?: stat.binary?,
        classification: classification,
        patch: patch,
        patch_line_count: count_lines(patch),
        hunk_headers: Map.get(hunk_headers, path, []),
        hunk_ranges: hunk_ranges(Map.get(hunk_headers, path, []))
      }
    end)
  end

  defp evidence_file_contents(inventory, git_fun) do
    inventory
    |> Enum.reject(&skip_evidence_file?/1)
    |> Enum.flat_map(fn %{path: path} ->
      case git_fun.(["show", "HEAD:#{path}"]) do
        {:ok, contents} when byte_size(contents) <= @max_evidence_file_bytes -> [{path, contents}]
        {:ok, _contents} -> []
        {:error, _reason} -> []
      end
    end)
    |> Map.new()
  end

  defp skip_evidence_file?(%{status: status, classification: classification}) when is_binary(status) do
    String.starts_with?(status, "D") or classification in [:binary, :generated, :lock]
  end

  defp skip_evidence_file?(%{classification: classification}) when classification in [:binary, :generated, :lock], do: true
  defp skip_evidence_file?(_file), do: false

  defp parse_numstat(numstat) do
    numstat
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_numstat_line/1)
    |> Map.new()
  end

  defp parse_numstat_line(line) do
    case String.split(line, "\t", trim: true) do
      [additions, deletions | path_parts] -> [{List.last(path_parts) || "", numstat_values(additions, deletions)}]
      _parts -> []
    end
  end

  defp numstat_values("-", _deletions), do: %{additions: nil, deletions: nil, binary?: true}
  defp numstat_values(_additions, "-"), do: %{additions: nil, deletions: nil, binary?: true}

  defp numstat_values(additions, deletions) do
    %{additions: parse_int(additions), deletions: parse_int(deletions), binary?: false}
  end

  defp file_patches(diff) do
    diff
    |> String.split(~r/(?=^diff --git )/m, trim: true)
    |> Map.new(fn patch ->
      {patch_path(patch), patch}
    end)
    |> Map.reject(fn {path, _patch} -> path in [nil, ""] end)
  end

  defp hunk_headers_by_path(diff) do
    diff
    |> String.split(~r/(?=^diff --git )/m, trim: true)
    |> Map.new(fn patch ->
      {patch_path(patch), Regex.scan(~r/^@@ .+@@.*$/m, patch) |> List.flatten()}
    end)
    |> Map.reject(fn {path, _headers} -> path in [nil, ""] end)
  end

  defp patch_path(patch) do
    case Regex.run(~r/^diff --git a\/.+ b\/(.+)$/m, patch, capture: :all_but_first) do
      [path] -> String.trim(path)
      _ -> nil
    end
  end

  defp hunk_ranges(headers) do
    headers
    |> Enum.flat_map(fn header ->
      case Regex.run(~r/@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/, header, capture: :all_but_first) do
        [start, length] -> [%{start: parse_int(start), length: max(parse_int(length), 1), header: header}]
        [start] -> [%{start: parse_int(start), length: 1, header: header}]
        _ -> []
      end
    end)
  end

  defp classify_path(path, binary?) do
    cond do
      binary? -> :binary
      Path.basename(path) in @lock_files -> :lock
      String.ends_with?(path, [".min.js", ".min.css"]) -> :generated
      String.contains?(path, ["/priv/static/", "/dist/", "/build/"]) -> :generated
      true -> :source
    end
  end

  defp render(context_pack) do
    files = context_pack.changed_files
    file_budget = per_file_budget(length(files))

    rendered_files =
      Enum.map(files, fn file ->
        {coverage, diff_text} = file_diff_text(file, file_budget)
        Map.put(file, :coverage, coverage) |> Map.put(:rendered_diff, diff_text)
      end)

    text =
      [
        render_issue(context_pack.issue),
        render_git(context_pack.git),
        render_inventory(context_pack.git.stat, rendered_files),
        render_files(rendered_files),
        render_adjacent_context(context_pack.adjacent_context),
        render_validation_evidence(context_pack.validation_evidence),
        render_rework_context(context_pack.reviewer_comments, context_pack.ci_failure),
        render_coverage(rendered_files, context_pack)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{text: text, files: rendered_files}
  end

  defp per_file_budget(0), do: 0

  defp per_file_budget(file_count) when file_count > 0 do
    @per_file_max
    |> max(file_count * @per_file_min)
    |> div(file_count)
    |> max(@per_file_min)
    |> min(@per_file_max)
  end

  defp file_diff_text(%{classification: classification}, _budget) when classification in [:generated, :lock, :binary] do
    {:summary, "(diff body summarized because file is #{classification})"}
  end

  defp file_diff_text(%{patch: patch, patch_line_count: line_count}, budget) when line_count <= budget do
    {:full, String.trim_trailing(patch)}
  end

  defp file_diff_text(%{patch: patch, patch_line_count: line_count}, budget) do
    shown =
      patch
      |> String.split("\n", trim: false)
      |> Enum.take(budget)
      |> Enum.join("\n")

    omitted = max(line_count - budget, 0)
    {:summary, String.trim_trailing(shown) <> "\n[Per-file diff summarized: omitted #{omitted} line(s).]"}
  end

  defp render_issue(issue) do
    matrix =
      issue.acceptance_matrix
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, index} ->
        criterion = present_linear(item.criterion, &PromptSafety.linear_issue_acceptance_criteria/1)
        "#{index}. #{criterion}\n   Evidence slots: []\n   Missing evidence: true"
      end)
      |> blank_fallback()

    """
    Issue intent:
    Title:
    #{issue.title}

    Description:
    #{issue.description}

    Acceptance criteria:
    #{blank_fallback(issue.acceptance_criteria)}

    Acceptance criteria matrix to fill:
    #{matrix}
    """
  end

  defp render_git(git) do
    """
    Git range: #{git.range}

    Commit subjects and bodies:
    #{blank_fallback(git.commit_messages)}
    """
  end

  defp render_inventory(stat, files) do
    rows =
      files
      |> Enum.map_join("\n", fn file ->
        additions = stat_value(file.additions)
        deletions = stat_value(file.deletions)
        "#{file.status}\t#{file.path}\t+#{additions} -#{deletions}\t#{file.classification}\tcoverage=#{file.coverage}"
      end)
      |> blank_fallback()

    """
    Changed file inventory:
    git diff --stat:
    #{blank_fallback(stat)}

    path	status	stat	classification	coverage
    #{rows}
    """
  end

  defp render_files(files) do
    body =
      files
      |> Enum.map_join("\n\n", fn file ->
        """
        File: #{file.path}
        Status: #{file.status}
        Classification: #{file.classification}
        Coverage: #{file.coverage}
        Hunk summary:
        #{format_hunks(file.hunk_headers)}

        Diff material:
        #{blank_fallback(file.rendered_diff)}
        """
      end)

    "Balanced diff slices:\n" <> body
  end

  defp render_adjacent_context(%{windows: [], same_name_tests: [], call_sites: []}) do
    "Adjacent source/test context:\n(none found or not readable)"
  end

  defp render_adjacent_context(context) do
    windows =
      context.windows
      |> Enum.map_join("\n\n", fn window ->
        """
        #{window.path}:#{window.start_line}-#{window.end_line}
        #{window.text}
        """
      end)
      |> blank_fallback()

    tests =
      context.same_name_tests
      |> Enum.map_join("\n\n", fn test ->
        """
        #{test.path}
        #{test.text}
        """
      end)
      |> blank_fallback()

    call_sites =
      context.call_sites
      |> Enum.map_join("\n", fn site -> "#{site.symbol}: #{site.location}" end)
      |> blank_fallback()

    """
    Adjacent source/test context:
    Nearby changed hunk windows:
    #{windows}

    Same-name tests:
    #{tests}

    Call-site lookup:
    #{call_sites}
    """
  end

  defp render_validation_evidence(%{present?: false}) do
    "Validation/workpad evidence:\n(none found)"
  end

  defp render_validation_evidence(workpad) do
    checklist =
      workpad.checklist_items
      |> Enum.map_join("\n", fn item -> "- [#{item.status}] #{item.text}" end)
      |> blank_fallback()

    commands = workpad.commands |> Enum.map_join("\n", &"- `#{&1}`") |> blank_fallback()

    """
    Validation/workpad evidence:
    Checklist:
    #{checklist}

    Commands/tests/manual checks:
    #{commands}

    Sanitized workpad excerpt:
    #{workpad.body}
    """
  end

  defp render_rework_context([], nil), do: "Rework context:\n(none)"

  defp render_rework_context(reviewer_comments, ci_failure) do
    comments =
      reviewer_comments
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {comment, index} ->
        "#{index}. #{comment_header(comment)}\n#{comment.body}"
      end)
      |> blank_fallback()

    ci =
      case ci_failure do
        nil ->
          "(none)"

        failure ->
          checks = failure.failed_checks |> Enum.map_join(", ", & &1.name) |> blank_fallback("unknown")

          """
          Failed checks: #{checks}
          Commit SHA: #{blank_fallback(failure.commit_sha, "unknown")}
          Log excerpt:
          #{failure.log_excerpt}
          """
      end

    """
    Rework context:
    Pending reviewer comments:
    #{comments}

    CI failure summary:
    #{ci}
    """
  end

  defp render_coverage(files, context_pack) do
    coverage = coverage_metadata(context_pack, %{files: files})

    """
    Summarized context coverage:
    Fully reviewed files: #{format_list(coverage.fully_reviewed_files)}
    Summarized files: #{format_list(coverage.summarized_files)}
    Generated/lock/binary summary files: #{format_list(coverage.generated_lock_files)}
    Adjacent context files: #{format_list(coverage.adjacent_context_files)}
    Adjacent context omitted files: #{format_list(coverage.adjacent_context_omitted_files)}
    Validation evidence count: #{coverage.validation_evidence_count}
    Reviewer comment count: #{coverage.reviewer_comment_count}
    CI context included: #{coverage.ci_context_included?}
    """
  end

  defp coverage_metadata(context_pack, rendered) do
    files = Map.get(rendered, :files, [])
    adjacent_files = context_pack.adjacent_context.windows |> Enum.map(& &1.path) |> Enum.uniq()
    changed_paths = Enum.map(context_pack.changed_files, & &1.path)

    %{
      fully_reviewed_files: files |> Enum.filter(&(&1.coverage == :full)) |> Enum.map(& &1.path),
      summarized_files: files |> Enum.filter(&(&1.coverage == :summary and &1.classification == :source)) |> Enum.map(& &1.path),
      generated_lock_files: files |> Enum.filter(&(&1.classification in [:generated, :lock, :binary])) |> Enum.map(& &1.path),
      adjacent_context_files: adjacent_files,
      adjacent_context_omitted_files: changed_paths -- adjacent_files,
      validation_evidence_count: validation_evidence_count(context_pack.validation_evidence),
      reviewer_comment_count: length(context_pack.reviewer_comments),
      ci_context_included?: not is_nil(context_pack.ci_failure)
    }
  end

  defp summarized?(coverage), do: coverage.summarized_files != []

  defp adjacent_context(_workspace, [], _git_fun, _opts), do: %{windows: [], same_name_tests: [], call_sites: []}

  defp adjacent_context(workspace, inventory, git_fun, opts) do
    changed_paths = Keyword.get(opts, :changed_paths, [])

    windows =
      inventory
      |> Enum.reject(&(&1.classification in [:binary]))
      |> Enum.flat_map(&file_windows(&1, git_fun))
      |> Enum.take(@max_adjacent_windows)

    same_name_tests = same_name_tests(changed_paths, git_fun)
    call_sites = call_sites(workspace, inventory, Keyword.get(opts, :worker_host))

    %{windows: windows, same_name_tests: same_name_tests, call_sites: call_sites}
  end

  defp file_windows(%{path: path, hunk_ranges: ranges, status: status}, git_fun) do
    if String.starts_with?(status, "D") do
      []
    else
      case git_fun.(["show", "HEAD:#{path}"]) do
        {:ok, contents} ->
          lines = String.split(contents, "\n", trim: false)

          ranges
          |> Enum.map(&line_window(path, lines, &1))
          |> Enum.reject(&is_nil/1)

        {:error, _reason} ->
          []
      end
    end
  end

  defp line_window(path, lines, %{start: start, length: length}) do
    start_line = max(start - @context_radius, 1)
    end_line = min(start + length + @context_radius, Kernel.length(lines))

    if start_line <= end_line do
      text =
        lines
        |> Enum.slice((start_line - 1)..(end_line - 1))
        |> Enum.with_index(start_line)
        |> Enum.map_join("\n", fn {line, number} -> "#{number}: #{line}" end)

      %{path: path, start_line: start_line, end_line: end_line, text: text}
    end
  end

  defp same_name_tests(changed_paths, git_fun) do
    case git_fun.(["ls-files"]) do
      {:ok, output} ->
        tracked = String.split(output, "\n", trim: true)

        changed_paths
        |> Enum.flat_map(&same_name_test_candidates(&1, tracked, git_fun))
        |> Enum.uniq_by(& &1.path)

      {:error, _reason} ->
        []
    end
  end

  defp same_name_test_candidates(path, tracked, git_fun) do
    base = Path.basename(path, Path.extname(path))

    tracked
    |> Enum.filter(fn candidate ->
      candidate != path and same_name_test?(candidate, base)
    end)
    |> Enum.flat_map(fn candidate ->
      case git_fun.(["show", "HEAD:#{candidate}"]) do
        {:ok, contents} -> [%{path: candidate, text: contents |> first_lines(80) |> String.trim_trailing()}]
        {:error, _reason} -> []
      end
    end)
  end

  defp same_name_test?(candidate, base) do
    Path.basename(candidate, Path.extname(candidate)) in [
      base <> "_test",
      base <> ".test",
      base <> "_spec",
      base <> ".spec"
    ]
  end

  defp call_sites(_workspace, _inventory, worker_host) when is_binary(worker_host), do: []

  defp call_sites(workspace, inventory, _worker_host) do
    case System.find_executable("rg") do
      nil ->
        Logger.info("ReviewAgent call-site lookup skipped: rg executable not on PATH")
        []

      rg ->
        symbols =
          inventory
          |> Enum.flat_map(&public_symbols/1)
          |> Enum.uniq()
          |> Enum.take(@max_symbols)

        Enum.flat_map(symbols, &rg_call_sites(rg, workspace, &1))
    end
  end

  defp public_symbols(%{patch: patch}) do
    patch
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      cond do
        match = Regex.run(~r/^\+\s*def(?:macro)?\s+([a-zA-Z_][\w?!]*)/, line, capture: :all_but_first) ->
          match

        match = Regex.run(~r/^\+\s*(?:export\s+)?function\s+([a-zA-Z_]\w*)/, line, capture: :all_but_first) ->
          match

        match = Regex.run(~r/^\+\s*(?:export\s+)?const\s+([a-zA-Z_]\w*)\s*=/, line, capture: :all_but_first) ->
          match

        true ->
          []
      end
    end)
  end

  defp rg_call_sites(rg, workspace, symbol) do
    case System.cmd(rg, ["--fixed-strings", "--line-number", "--", symbol, workspace], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.take(@max_call_sites_per_symbol)
        |> Enum.map(&%{symbol: symbol, location: &1})

      {_output, _status} ->
        []
    end
  end

  defp workpad_evidence(comments) when is_list(comments) do
    markers = AgentLabels.known_workpad_markers()

    case Enum.find(comments, fn comment -> Enum.any?(markers, &String.contains?(to_string(Map.get(comment, :body, "")), &1)) end) do
      nil ->
        %{present?: false, body: "", checklist_items: [], commands: []}

      comment ->
        body = Map.get(comment, :body, "")

        %{
          present?: true,
          body: present_linear(body, &PromptSafety.linear_issue_comment_body/1),
          checklist_items: checklist_items(body),
          commands: validation_commands(body)
        }
    end
  end

  defp workpad_evidence(_comments), do: %{present?: false, body: "", checklist_items: [], commands: []}

  defp checklist_items(body) when is_binary(body) do
    ~r/^\s*-\s+\[(x|X| )\]\s+(.+)$/m
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [status, text] -> %{status: if(String.trim(status) == "", do: " ", else: "x"), text: String.trim(text)} end)
  end

  defp validation_commands(body) when is_binary(body) do
    validation_section(body)
    |> then(&Regex.scan(~r/`([^`\n]+)`/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validation_section(body) do
    case Regex.run(~r/^###\s+Validation\s*(.*?)(?=^###\s+|\z)/ims, body, capture: :all_but_first) do
      [section] -> section
      _ -> body
    end
  end

  defp reviewer_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_reviewer_comment/1)
    |> Enum.reject(&(String.trim(Map.get(&1, :body, "")) == ""))
  end

  defp reviewer_comments(_comments), do: []

  defp normalize_reviewer_comment(comment) when is_map(comment) do
    %{
      author: string_field(comment, :author) || "Reviewer",
      body: comment |> string_field(:body) |> present_linear(&PromptSafety.linear_reviewer_comment_body/1),
      kind: string_field(comment, :kind),
      path: string_field(comment, :path),
      line: integer_field(comment, :line),
      url: string_field(comment, :url)
    }
  end

  defp normalize_reviewer_comment(_comment), do: %{body: ""}

  defp ci_failure(failure) when is_map(failure) do
    failed_checks =
      failure
      |> Map.get(:failed_checks, Map.get(failure, "failed_checks", []))
      |> Enum.map(&normalize_ci_check/1)
      |> Enum.reject(&(&1.name == ""))

    log_excerpt = string_field(failure, :log_excerpt) || ""
    commit_sha = string_field(failure, :commit_sha)

    if failed_checks == [] and String.trim(log_excerpt) == "" and is_nil(commit_sha) do
      nil
    else
      %{
        failed_checks: failed_checks,
        commit_sha: commit_sha,
        log_excerpt: PromptSafety.ci_failure_log_excerpt(log_excerpt)
      }
    end
  end

  defp ci_failure(_failure), do: nil

  defp normalize_ci_check(check) when is_map(check) do
    %{
      name: string_field(check, :name) || "",
      conclusion: string_field(check, :conclusion),
      run_id: string_field(check, :run_id)
    }
  end

  defp normalize_ci_check(_check), do: %{name: "", conclusion: nil, run_id: nil}

  defp validation_evidence_count(%{present?: false}), do: 0

  defp validation_evidence_count(workpad) do
    length(workpad.checklist_items) + length(workpad.commands)
  end

  defp acceptance_criteria(description) when is_binary(description) do
    case Regex.run(~r/^##\s+Acceptance criteria\s*(.*?)(?=^##\s+|\z)/ims, description, capture: :all_but_first) do
      [criteria] -> String.trim(criteria)
      _ -> ""
    end
  end

  defp acceptance_criteria(_description), do: ""

  defp acceptance_criteria_items(criteria) when is_binary(criteria) do
    criteria
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, ["- ", "* "]))
    |> Enum.map(&Regex.replace(~r/^[-*]\s+/, &1, ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp linear_input_warnings(issue, acceptance_criteria, workpad, reviewer_comments, ci_failure) do
    reviewer_warning_sources =
      reviewer_comments
      |> Enum.with_index()
      |> Enum.map(fn {comment, index} -> {"reviewer_comments[#{index}].body", comment.body} end)

    [
      {"issue.title", issue.title},
      {"issue.description", issue.description},
      {"issue.acceptance_criteria", acceptance_criteria},
      {"workpad.body", if(workpad.present?, do: workpad.body, else: nil)}
    ]
    |> Kernel.++(reviewer_warning_sources)
    |> Kernel.++(ci_failure_warning_sources(ci_failure))
    |> PromptSafety.warning_fields()
  end

  defp ci_failure_warning_sources(nil), do: []
  defp ci_failure_warning_sources(ci_failure), do: [{"ci_failure.log_excerpt", ci_failure.log_excerpt}]

  defp comment_header(comment) do
    [
      "#{blank_fallback(comment.author, "Reviewer")}:",
      comment.kind && "[#{comment.kind}]",
      comment.path,
      comment.line && "line #{comment.line}",
      comment.url
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp format_hunks([]), do: "(none)"
  defp format_hunks(headers), do: Enum.join(headers, "\n")

  defp format_list([]), do: "(none)"
  defp format_list(values), do: Enum.join(values, ", ")

  defp stat_value(nil), do: "?"
  defp stat_value(value), do: to_string(value)

  defp first_lines(text, count) do
    text
    |> String.split("\n", trim: false)
    |> Enum.take(count)
    |> Enum.join("\n")
  end

  defp count_lines(""), do: 0
  defp count_lines(text) when is_binary(text), do: length(String.split(text, "\n", trim: false))

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp blank_fallback(value, fallback \\ "(none)")

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      _ -> value
    end
  end

  defp blank_fallback(value, fallback) when is_nil(value), do: fallback
  defp blank_fallback(value, _fallback), do: to_string(value)

  defp present_linear(value, _renderer) when value in [nil, ""], do: ""
  defp present_linear(value, renderer) when is_binary(value), do: renderer.(value)
  defp present_linear(value, renderer), do: value |> to_string() |> renderer.()

  defp string_field(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_string(key))) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp integer_field(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_string(key))) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value)
      _ -> nil
    end
  end
end
