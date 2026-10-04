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

  @doc "Whether `path` matches the glob (`**` spans directories, `*` and `?` do not)."
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(path, glob) when is_binary(path) and is_binary(glob) do
    Regex.match?(glob_regex(glob), path)
  end

  @doc "The enabled playbooks: built-ins with config overrides, plus config-defined kinds."
  @spec playbooks(map(), keyword()) :: [playbook()]
  def playbooks(auto_review, opts \\ []) do
    host = %{dev_server?: Keyword.get(opts, :dev_server?, false), android_avd?: android_avd?(auto_review)}
    overrides = stringify_keys(Map.get(auto_review, :playbooks) || %{})

    custom_kinds =
      overrides
      |> Map.keys()
      |> Enum.reject(&(&1 in @built_in_kinds))
      |> Enum.sort()

    (@built_in_kinds ++ custom_kinds)
    |> Enum.flat_map(&build_playbook(&1, Map.get(overrides, &1), host))
  end

  defp android_avd?(auto_review) do
    case Map.get(auto_review, :android) do
      %{avd: avd} -> string_value(avd) != nil
      _unset -> false
    end
  end

  defp build_playbook(kind, override, host) do
    override = if is_map(override), do: stringify_keys(override), else: %{}
    prompt = string_value(Map.get(override, "prompt")) || Map.get(@built_in_prompts, kind)
    paths = string_list(Map.get(override, "paths")) || Map.get(@built_in_paths, kind, [])

    cond do
      Map.get(override, "enabled") == false or is_nil(prompt) -> []
      not required_settings?(kind, override, host) -> []
      true -> [put_host_settings(%{kind: kind, paths: paths, prompt: prompt}, kind, override)]
    end
  end

  # The `web` playbook drives the verification dev server, so it needs one configured.
  defp required_settings?("web", _override, host), do: host.dev_server?

  # The `android_app` playbook also needs the app's IDs and an emulator to run it on.
  defp required_settings?("android_app", override, host) do
    host.android_avd? and application_ids(override) != [] and named_settings?("android_app", override)
  end

  defp required_settings?(kind, override, _host), do: named_settings?(kind, override)

  defp named_settings?(kind, override) do
    @required_settings
    |> Map.get(kind, [])
    |> Enum.all?(&string_value(Map.get(override, &1)))
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
    Enum.any?(@docs_and_test_globs ++ skip_globs, &glob_match?(path, &1))
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
