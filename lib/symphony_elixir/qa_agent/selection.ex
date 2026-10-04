defmodule SymphonyElixir.QaAgent.Selection do
  @moduledoc """
  Decides, without an agent, whether a PR head gets a QA pass and which playbooks
  the QA agent follows.

  The decision uses only the changed paths, the issue labels and the issue body:

  - a `qa:skip` label skips QA;
  - a `qa:<kind>` label always selects that playbook;
  - a diff that only touches docs, tests or `auto_review.skip_globs` is skipped;
  - otherwise each playbook is selected by its trigger paths or, for the `cli`
    playbook, a `## User walkthrough` section in the ticket;
  - when nothing is selected (an internal refactor, say), QA is skipped.

  Built-in playbooks ship as `priv/qa_playbooks/<kind>.md`. `auto_review.playbooks`
  can override a built-in's `paths`, turn it off with `enabled: false`, or add a new
  kind with `paths` and `prompt`.

  The built-in `macos_app` playbook is on only when its config names the `build`
  command and the `app` bundle (relative to the repo root) that the host-side
  `qa_*` tools of `SymphonyElixir.QaDriver` build and launch. The built-in `web`
  playbook is on only when `verification.dev_server` is configured
  (`dev_server?: true`), since its pass drives that server in a browser; its
  optional `browser_mcp` replaces the default Playwright MCP server. The built-in
  `android_app` playbook is on only when its config names the `build` command the
  QA agent runs in its sandbox, the `apk_path` it writes and the app's
  `application_ids`, and `auto_review.android.avd` names the emulator that the
  host-side `qa_android_*` tools of `SymphonyElixir.QaAndroid.Driver` drive.
  """

  alias SymphonyElixir.Linear.Issue

  @skip_label "qa:skip"
  @label_prefix "qa:"
  @walkthrough_heading ~r/^\#{2,6}[ \t]*User walkthrough[ \t]*$/mi

  @docs_and_test_globs ~w(
    **/*.md
    **/*.mdx
    **/*.rst
    **/*.txt
    docs/**
    **/LICENSE*
    test/**
    **/test/**
    tests/**
    **/tests/**
    spec/**
    **/__tests__/**
    **/src/test/**
    **/src/androidTest/**
    **/*_test.exs
    **/*_test.go
    **/*.test.*
    **/*.spec.*
    macos/Tests/**
  )

  @source_root Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "qa_playbooks"]))
  @built_in_kinds ~w(cli macos_app android_app web)

  for kind <- @built_in_kinds do
    @external_resource Path.join(@source_root, kind <> ".md")
  end

  @built_in_prompts (for kind <- @built_in_kinds, into: %{} do
                       {kind, File.read!(Path.join(@source_root, kind <> ".md"))}
                     end)

  @built_in_paths %{
    "cli" => ["bin/**", "lib/symphony_elixir/cli.ex", "lib/mix/tasks/**"],
    "macos_app" => ["**/*.swift", "**/Info.plist", "**/*.xib", "**/*.storyboard", "**/*.xcassets/**"],
    "android_app" => ["**/*.kt", "**/*.java", "**/AndroidManifest.xml", "**/src/main/res/**", "**/*.gradle.kts", "**/*.gradle"],
    "web" => [
      "lib/*_web/**",
      "lib/*_web.ex",
      "priv/static/**",
      "assets/**",
      "**/*.heex",
      "**/*.html",
      "**/*.css",
      "**/*.scss",
      "**/*.jsx",
      "**/*.tsx",
      "**/*.vue",
      "**/*.svelte"
    ]
  }

  # Playbooks that need host-side settings before they can run.
  @required_settings %{"macos_app" => ["build", "app"], "android_app" => ["build", "apk_path"]}

  # Playbooks the ticket's `## User walkthrough` section selects.
  @walkthrough_kinds ["cli"]

  @type playbook :: %{
          required(:kind) => String.t(),
          required(:paths) => [String.t()],
          required(:prompt) => String.t(),
          optional(:build) => String.t(),
          optional(:app) => String.t(),
          optional(:build_timeout_ms) => pos_integer() | nil,
          optional(:apk_path) => String.t(),
          optional(:application_ids) => [String.t()],
          optional(:browser_mcp) => map() | nil
        }
  @type decision :: {:run, [playbook()]} | {:skip, String.t()}

  @doc """
  Selects playbooks for `issue` given the PR's changed paths and `auto_review` config.
  `dev_server?: true` says `verification.dev_server` is configured, which the `web`
  playbook needs; the `android_app` playbook reads `auto_review.android.avd`.
  """
  @spec decide(Issue.t(), [String.t()], map(), keyword()) :: decision()
  def decide(%Issue{} = issue, changed_paths, auto_review, opts \\ []) when is_list(changed_paths) do
    labels = issue |> Issue.label_names() |> Enum.map(&normalize_label/1)
    playbooks = playbooks(auto_review, opts)
    skip_globs = Map.get(auto_review, :skip_globs) || []

    cond do
      @skip_label in labels ->
        {:skip, "the issue has the `qa:skip` label"}

      (labelled = labelled_playbooks(playbooks, labels)) != [] ->
        {:run, labelled}

      changed_paths == [] ->
        {:skip, "the PR changes no files"}

      Enum.all?(changed_paths, &docs_test_or_skipped?(&1, skip_globs)) ->
        {:skip, "the PR only changes docs, tests or `auto_review.skip_globs` paths"}

      (triggered = triggered_playbooks(playbooks, issue, changed_paths)) != [] ->
        {:run, triggered}

      true ->
        {:skip, "no QA playbook applies: no `## User walkthrough` in the ticket, no entry-point change, and no `qa:<kind>` label"}
    end
  end

  @doc "Whether the issue body has a `## User walkthrough` section."
  @spec user_walkthrough?(Issue.t()) :: boolean()
  def user_walkthrough?(%Issue{description: description}) when is_binary(description),
    do: Regex.match?(@walkthrough_heading, description)

  def user_walkthrough?(_issue), do: false

  @doc "Whether `path` is a docs or test file, by the globs that skip QA for docs/test-only diffs."
  @spec docs_or_test?(String.t()) :: boolean()
  def docs_or_test?(path) when is_binary(path), do: Enum.any?(@docs_and_test_globs, &glob_match?(path, &1))

  @doc "Whether `path` matches the glob (`**` spans directories, `*` and `?` do not)."
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(path, glob) when is_binary(path) and is_binary(glob) do
    Regex.match?(glob_regex(glob), path)
  end

  @doc "The enabled playbooks: built-ins with config overrides, plus config-defined kinds."
  @spec playbooks(map(), keyword()) :: [playbook()]
  def playbooks(auto_review, opts \\ []) do
    {overrides, host} = playbook_inputs(auto_review, opts)

    overrides
    |> kinds()
    |> Enum.flat_map(fn kind ->
      override = override(overrides, kind)
      if off_reason(kind, override, host), do: [], else: [build_playbook(kind, override)]
    end)
  end

  @doc """
  The playbooks that are off, each with why: `enabled: false`, or a setting it needs
  that the repo's `WORKFLOW.md` or the host's `symphony.yml` does not set.
  """
  @spec unavailable(map(), keyword()) :: [{String.t(), String.t()}]
  def unavailable(auto_review, opts \\ []) do
    {overrides, host} = playbook_inputs(auto_review, opts)

    overrides
    |> kinds()
    |> Enum.flat_map(fn kind ->
      case off_reason(kind, override(overrides, kind), host) do
        nil -> []
        reason -> [{kind, reason}]
      end
    end)
  end

  defp playbook_inputs(auto_review, opts) do
    host = %{dev_server?: Keyword.get(opts, :dev_server?, false), android_avd?: android_avd?(auto_review)}
    {stringify_keys(Map.get(auto_review, :playbooks) || %{}), host}
  end

  defp kinds(overrides) do
    custom_kinds =
      overrides
      |> Map.keys()
      |> Enum.reject(&(&1 in @built_in_kinds))
      |> Enum.sort()

    @built_in_kinds ++ custom_kinds
  end

  defp override(overrides, kind) do
    case Map.get(overrides, kind) do
      override when is_map(override) -> stringify_keys(override)
      _unset -> %{}
    end
  end

  defp android_avd?(auto_review) do
    case Map.get(auto_review, :android) do
      %{avd: avd} -> string_value(avd) != nil
      _unset -> false
    end
  end

  defp build_playbook(kind, override) do
    put_host_settings(%{kind: kind, paths: paths(kind, override), prompt: prompt(kind, override)}, kind, override)
  end

  defp prompt(kind, override), do: string_value(Map.get(override, "prompt")) || Map.get(@built_in_prompts, kind)
  defp paths(kind, override), do: string_list(Map.get(override, "paths")) || Map.get(@built_in_paths, kind, [])

  defp off_reason(kind, override, host) do
    cond do
      Map.get(override, "enabled") == false -> "`enabled: false`"
      is_nil(prompt(kind, override)) -> "no `prompt`"
      (missing = missing_settings(kind, override, host)) != [] -> "needs " <> Enum.map_join(missing, ", ", &"`#{&1}`")
      true -> nil
    end
  end

  # The `web` playbook drives the verification dev server, so it needs one configured.
  defp missing_settings("web", _override, host), do: if(host.dev_server?, do: [], else: ["verification.dev_server"])

  # The `android_app` playbook also needs the app's IDs and an emulator to run it on.
  defp missing_settings("android_app", override, host) do
    named = missing_named_settings("android_app", override)
    ids = if application_ids(override) == [], do: ["auto_review.playbooks.android_app.application_ids"], else: []
    avd = if host.android_avd?, do: [], else: ["auto_review.android.avd"]
    named ++ ids ++ avd
  end

  defp missing_settings(kind, override, _host), do: missing_named_settings(kind, override)

  defp missing_named_settings(kind, override) do
    for key <- Map.get(@required_settings, kind, []), is_nil(string_value(Map.get(override, key))), do: "auto_review.playbooks.#{kind}.#{key}"
  end

  defp application_ids(override) do
    override |> Map.get("application_ids") |> string_list() |> List.wrap() |> Enum.filter(&string_value/1)
  end

  defp put_host_settings(playbook, "macos_app", override) do
    timeout = Map.get(override, "build_timeout_ms")

    Map.merge(playbook, %{
      build: Map.fetch!(override, "build"),
      app: Map.fetch!(override, "app"),
      build_timeout_ms: if(is_integer(timeout) and timeout > 0, do: timeout)
    })
  end

  defp put_host_settings(playbook, "android_app", override) do
    Map.merge(playbook, %{
      build: Map.fetch!(override, "build"),
      apk_path: Map.fetch!(override, "apk_path"),
      application_ids: application_ids(override)
    })
  end

  defp put_host_settings(playbook, "web", override) do
    case Map.get(override, "browser_mcp") do
      %{} = browser_mcp -> Map.put(playbook, :browser_mcp, stringify_keys(browser_mcp))
      _default -> playbook
    end
  end

  defp put_host_settings(playbook, _kind, _override), do: playbook

  defp labelled_playbooks(playbooks, labels) do
    Enum.filter(playbooks, &((@label_prefix <> &1.kind) in labels))
  end

  defp triggered_playbooks(playbooks, issue, changed_paths) do
    walkthrough? = user_walkthrough?(issue)

    Enum.filter(playbooks, fn playbook ->
      (walkthrough? and playbook.kind in @walkthrough_kinds) or
        Enum.any?(changed_paths, fn path -> Enum.any?(playbook.paths, &glob_match?(path, &1)) end)
    end)
  end

  defp docs_test_or_skipped?(path, skip_globs) do
    docs_or_test?(path) or Enum.any?(skip_globs, &glob_match?(path, &1))
  end

  defp glob_regex(glob) do
    body =
      ~r/\*\*\/|\*\*|\*|\?|[^*?]+/
      |> Regex.scan(glob)
      |> Enum.map_join(fn
        ["**/"] -> "(?:.*/)?"
        ["**"] -> ".*"
        ["*"] -> "[^/]*"
        ["?"] -> "[^/]"
        [literal] -> Regex.escape(literal)
      end)

    Regex.compile!("\\A" <> body <> "\\z")
  end

  defp normalize_label(label), do: label |> String.trim() |> String.downcase()

  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp string_value(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp string_value(_value), do: nil

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: nil
end
