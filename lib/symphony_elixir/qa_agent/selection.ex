defmodule SymphonyElixir.QaAgent.Selection do
  @moduledoc """
  Decides, without an agent, whether a PR head gets a QA pass and which playbooks
  the QA agent follows.

  The decision uses only the changed paths, the issue labels, the issue body and the ticket's plan:

  - a `qa:skip` label skips QA;
  - a `qa:<kind>` label always selects that playbook;
  - a diff that only touches docs, tests or `auto_review.skip_globs` is skipped;
  - otherwise each playbook is selected by its trigger paths or, for the `cli`
    playbook, a `## User walkthrough` section in the ticket, and the `macos_app`
    playbook also when the plan sets a QA check it walks on its `live` server (`live/1`);
  - when nothing is selected (an internal refactor, say), QA is skipped.

  Built-in playbooks ship as `priv/qa_playbooks/<kind>.md`. `auto_review.playbooks`
  can override a built-in's `paths`, turn it off with `enabled: false`, or add a new
  kind with `paths` and `prompt`. The built-in `macos_app` playbook's text is built at compile
  time by `SymphonyElixir.QaAgent.PromptTerms` (its statuses and QA tools from their one
  definition, no window size by hand); a repo's own `prompt` is used as it is.

  The built-in `macos_app` playbook is on only when its config names the `build`
  command and the `app` bundle (relative to the repo root) that the host-side
  `qa_*` tools of `SymphonyElixir.QaDriver` build and launch. The built-in `web`
  playbook is on only when `verification.enabled` is on and `verification.dev_server`
  is configured (`dev_server?: true`), since its pass drives that server on this host
  in a browser; its optional `browser_mcp` replaces the default Playwright MCP server.
  The project's server is described once, in `verification.dev_server`, and its `runs` rule says
  when it runs (`dev_server_runs:`, TP-1663): `symphony_host` keeps it on this host, for agent
  runs and `web` passes; `every_qa_pass` runs it on the QA host beside every `macos_app` pass
  (the playbook is carried with `dev_server: true`); `live_qa_pass` runs it there beside a
  `macos_app` pass `live/1` says is live (the playbook is carried with `live_server: true`). Both
  need only `verification.dev_server` (`dev_server_command?: true`), never `verification.enabled`,
  which turns on this host's server. The `macos_app` playbook's server listens on its
  `dev_server_port`, and its `launch_env` reaches the app (see
  `SymphonyElixir.PlaybookSettings`), which also gives it the QA target, its `:window_size` and
  `:appearance`. When `live/1` says a live server should run (the plan sets a QA check QA walks on
  the live server), the playbook is selected even for a diff outside its own paths, and
  `SymphonyElixir.QaPolicy` marks the pass `live: true`. No word in a ticket or a walkthrough and
  no changed path decides it. The built-in
  `android_app` playbook is on only when its config names the `build` command the
  QA agent runs in its sandbox, the APKs it writes (`apk_paths`, or one
  `apk_path`) and the apps' `application_ids`, and `auto_review.android.avd` names the emulator that the
  host-side `qa_android_*` tools of `SymphonyElixir.QaAndroid.Driver` drive.

  Any playbook may list `requires`, the executables its pass needs on the QA host
  (default none). `SymphonyElixir.QaDriver` checks the `macos_app` playbook's with
  `command -v` when the pass starts.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PlaybookSettings
  alias SymphonyElixir.QaAgent.PromptTerms
  alias SymphonyElixir.TicketJourney

  @skip_label "qa:skip"
  @live_label "qa:live"
  @fixture_label "qa:fixture"
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

  # The built-ins whose text is built from the prompt terms' definitions.
  @built_prompt_kinds ~w(macos_app)

  @built_in_prompts (for kind <- @built_in_kinds, into: %{} do
                       text = File.read!(Path.join(@source_root, kind <> ".md"))

                       if kind in @built_prompt_kinds,
                         do: {kind, PromptTerms.build!("priv/qa_playbooks/#{kind}.md", text, PromptTerms.terms())},
                         else: {kind, text}
                     end)

  # A built-in also triggers on its own instructions (`priv/qa_playbooks/<kind>.md`) and on the
  # host driver behind its tools: only a pass that runs the playbook can check a change to either
  # (TP-1068).
  @built_in_paths %{
    "cli" => ["bin/**", "lib/symphony_elixir/cli.ex", "lib/mix/tasks/**"],
    "macos_app" => [
      "**/*.swift",
      "**/Info.plist",
      "**/*.xib",
      "**/*.storyboard",
      "**/*.xcassets/**",
      "lib/symphony_elixir/qa_driver.ex",
      "lib/symphony_elixir/qa_driver/**",
      "priv/qa_driver/**"
    ],
    "android_app" => [
      "**/*.kt",
      "**/*.java",
      "**/AndroidManifest.xml",
      "**/src/main/res/**",
      "**/*.gradle.kts",
      "**/*.gradle",
      "lib/symphony_elixir/qa_android/**"
    ],
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
  @required_settings %{"macos_app" => ["build", "app"], "android_app" => ["build"]}

  # Playbooks the ticket's `## User walkthrough` section selects.
  @walkthrough_kinds ["cli"]

  @type playbook :: %{
          required(:kind) => String.t(),
          required(:paths) => [String.t()],
          required(:prompt) => String.t(),
          optional(:build) => String.t(),
          optional(:app) => String.t(),
          optional(:build_timeout_ms) => pos_integer() | nil,
          optional(:dev_server_port) => pos_integer(),
          optional(:launch_env) => %{optional(String.t()) => String.t()},
          optional(:window_size) => {pos_integer(), pos_integer()},
          optional(:appearance) => String.t(),
          optional(:apk_paths) => [String.t()],
          optional(:application_ids) => [String.t()],
          optional(:browser_mcp) => map() | nil,
          optional(:dev_server) => true,
          optional(:requires) => [String.t()],
          optional(:scope) => :none,
          optional(:live_server) => true,
          optional(:live) => true,
          optional(:live_reason) => String.t()
        }
  @type decision :: {:run, [playbook()]} | {:skip, String.t()}

  @doc """
  Selects playbooks for `issue` given the PR's changed paths and `auto_review` config.
  `dev_server?: true` says `verification` is on and `verification.dev_server` is configured to run
  on this host, which the `web` playbook needs (`verification_enabled?:` says whether `verification`
  is on, so the reason names the switch or the `runs` rule); `dev_server_command?: true` says
  `verification.dev_server` is configured, which is all the `macos_app` playbook needs when
  `dev_server_runs:` (its `runs` rule) runs it on the QA host. The `android_app` playbook
  reads `auto_review.android.avd`.
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

  @doc """
  Whether a `macos_app` playbook's `live` server runs for this ticket's QA pass, and why. The plan
  decides: the pass is live when a QA check QA still walks (not waived, no recorded test proves it)
  is set to the live server (its `setting.source` is `live`; `SymphonyElixir.TicketJourney.live_checks/1`),
  whatever its text says, and the reason names those checks. No word in a step and no changed path
  makes a pass live. A plan whose QA checks carry no setting (written before settings), and a ticket
  with no plan, get fixtures only. A `qa:live` label makes it run and a `qa:fixture` label never
  does; `qa:fixture` wins over `qa:live`.
  """
  @spec live(Issue.t()) :: {boolean(), String.t()}
  def live(%Issue{} = issue) do
    labels = issue |> Issue.label_names() |> Enum.map(&normalize_label/1)

    cond do
      @fixture_label in labels -> {false, "the issue has the `#{@fixture_label}` label"}
      @live_label in labels -> {true, "the issue has the `#{@live_label}` label"}
      (ids = TicketJourney.live_checks(issue)) != [] -> {true, live_checks_reason(ids)}
      TicketJourney.groomed?(issue) -> {false, "no QA check of the plan that QA walks is set to the live server"}
      true -> {false, "the ticket has no plan, so no QA check is set to the live server"}
    end
  end

  defp live_checks_reason([id]), do: "the plan's QA check #{id} is set to the live server"
  defp live_checks_reason(ids), do: "the plan's QA checks #{Enum.join(ids, ", ")} are set to the live server"

  @doc "Whether the issue body has a `## User walkthrough` section, or its plan a QA check (`SymphonyElixir.TicketJourney`)."
  @spec user_walkthrough?(Issue.t()) :: boolean()
  def user_walkthrough?(issue), do: TicketJourney.walkthrough?(issue, &walkthrough_heading?/1)

  defp walkthrough_heading?(description), do: is_binary(description) and Regex.match?(@walkthrough_heading, description)

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
      if off_reason(kind, override, host), do: [], else: [build_playbook(kind, override, host)]
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
    dev_server? = Keyword.get(opts, :dev_server?, false)

    host = %{
      dev_server?: dev_server?,
      verification_enabled?: Keyword.get(opts, :verification_enabled?, dev_server?),
      dev_server_command?: Keyword.get(opts, :dev_server_command?, dev_server?),
      dev_server_runs: Keyword.get(opts, :dev_server_runs, "symphony_host"),
      android_avd?: android_avd?(auto_review)
    }

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

  defp build_playbook(kind, override, host) do
    playbook = %{kind: kind, paths: paths(kind, override), prompt: prompt(kind, override)}
    playbook = if dev_server?(kind, host), do: Map.put(playbook, :dev_server, true), else: playbook
    playbook = put_requires(playbook, override)
    put_host_settings(playbook, kind, override, host)
  end

  # The executables the pass needs on the QA host, trimmed and without repeats.
  defp put_requires(playbook, override) do
    case override |> Map.get("requires") |> string_list() |> List.wrap() |> Enum.flat_map(&List.wrap(string_value(&1))) do
      [] -> playbook
      requires -> Map.put(playbook, :requires, requires |> Enum.map(&String.trim/1) |> Enum.uniq())
    end
  end

  defp prompt(kind, override), do: string_value(Map.get(override, "prompt")) || Map.get(@built_in_prompts, kind)
  defp paths(kind, override), do: string_list(Map.get(override, "paths")) || built_in_paths(kind)

  defp built_in_paths(kind) when kind in @built_in_kinds, do: ["priv/qa_playbooks/#{kind}.md" | Map.fetch!(@built_in_paths, kind)]
  defp built_in_paths(_kind), do: []

  defp off_reason(kind, override, host) do
    cond do
      Map.get(override, "enabled") == false ->
        "`enabled: false`"

      is_nil(prompt(kind, override)) ->
        "no `prompt`"

      (missing = missing_settings(kind, override, host) ++ missing_dev_server(kind, override, host)) != [] ->
        "needs " <> Enum.map_join(missing, ", ", &"`#{&1}`")

      true ->
        nil
    end
  end

  # The `android_app` playbook also needs an APK, the app's IDs and an emulator to run it on.
  defp missing_settings("android_app", override, host) do
    named = missing_named_settings("android_app", override)
    # Either key will do; the reason wraps each entry in backticks.
    apks = if apk_paths(override) == [], do: ["auto_review.playbooks.android_app.apk_path` or `auto_review.playbooks.android_app.apk_paths"], else: []
    ids = if application_ids(override) == [], do: ["auto_review.playbooks.android_app.application_ids"], else: []
    avd = if host.android_avd?, do: [], else: ["auto_review.android.avd"]
    named ++ apks ++ ids ++ avd
  end

  defp missing_settings(kind, override, _host), do: missing_named_settings(kind, override)

  defp missing_named_settings(kind, override) do
    for key <- Map.get(@required_settings, kind, []), is_nil(string_value(Map.get(override, key))), do: "auto_review.playbooks.#{kind}.#{key}"
  end

  # A playbook that drives the project's server needs one configured: the `web` one on this host,
  # which `verification.enabled` and `runs: symphony_host` turn on, and the `macos_app` one with
  # `runs: every_qa_pass` on the QA host, which reads only `verification.dev_server`. With
  # verification on, a `web` playbook whose server runs on the QA host names the rule instead.
  defp missing_dev_server(kind, _override, host) do
    cond do
      not dev_server?(kind, host) -> []
      not host.dev_server_command? -> ["verification.dev_server"]
      kind == "macos_app" -> []
      host.dev_server? -> []
      not host.verification_enabled? -> ["verification.enabled"]
      true -> ["verification.dev_server.runs: symphony_host"]
    end
  end

  defp dev_server?("web", _host), do: true
  defp dev_server?("macos_app", host), do: host.dev_server_runs == "every_qa_pass"
  defp dev_server?(_kind, _host), do: false

  defp application_ids(override) do
    override |> Map.get("application_ids") |> string_list() |> List.wrap() |> Enum.filter(&string_value/1)
  end

  # `apk_path` is a one-item `apk_paths`; a playbook may set both.
  defp apk_paths(override) do
    paths = [Map.get(override, "apk_path") | override |> Map.get("apk_paths") |> string_list() |> List.wrap()]
    paths |> Enum.filter(&string_value/1) |> Enum.uniq()
  end

  defp put_host_settings(playbook, "macos_app", override, host) do
    timeout = Map.get(override, "build_timeout_ms")
    port = Map.get(override, "dev_server_port")
    launch_env = Map.get(override, "launch_env")

    playbook =
      Map.merge(playbook, %{
        build: Map.fetch!(override, "build"),
        app: Map.fetch!(override, "app"),
        build_timeout_ms: if(is_integer(timeout) and timeout > 0, do: timeout),
        dev_server_port: if(is_integer(port) and port in 1..65_535, do: port, else: PlaybookSettings.default_port()),
        launch_env: if(is_map(launch_env), do: stringify_keys(launch_env), else: %{}),
        window_size: PlaybookSettings.window_size(override),
        appearance: PlaybookSettings.appearance(override)
      })

    if host.dev_server_runs == "live_qa_pass" and host.dev_server_command?,
      do: Map.put(playbook, :live_server, true),
      else: playbook
  end

  defp put_host_settings(playbook, "android_app", override, _host) do
    Map.merge(playbook, %{
      build: Map.fetch!(override, "build"),
      apk_paths: apk_paths(override),
      application_ids: application_ids(override)
    })
  end

  defp put_host_settings(playbook, "web", override, _host) do
    case Map.get(override, "browser_mcp") do
      %{} = browser_mcp -> Map.put(playbook, :browser_mcp, stringify_keys(browser_mcp))
      _default -> playbook
    end
  end

  defp put_host_settings(playbook, _kind, _override, _host), do: playbook

  defp labelled_playbooks(playbooks, labels) do
    Enum.filter(playbooks, &((@label_prefix <> &1.kind) in labels))
  end

  defp triggered_playbooks(playbooks, issue, changed_paths) do
    walkthrough? = user_walkthrough?(issue)

    Enum.filter(playbooks, fn playbook ->
      (walkthrough? and playbook.kind in @walkthrough_kinds) or live_server_runs?(playbook, issue) or
        Enum.any?(changed_paths, fn path -> Enum.any?(playbook.paths, &glob_match?(path, &1)) end)
    end)
  end

  # A `macos_app` playbook whose live server the plan asks for is selected for a diff outside its paths too.
  defp live_server_runs?(%{live_server: _live_server}, issue), do: elem(live(issue), 0)
  defp live_server_runs?(_playbook, _issue), do: false

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
