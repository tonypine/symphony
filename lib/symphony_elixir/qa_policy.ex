defmodule SymphonyElixir.QaPolicy do
  @moduledoc """
  The QA state's skip rule: which changes need a QA run, and which skip it.

  The rule is hybrid, as the design says. A deterministic rule skips QA automatically when the
  changed paths are all docs, tests or `auto_review.skip_globs` paths (or no playbook applies);
  everything else runs it. A head that changes no paths at all is neither: there is nothing to
  verify, and the ticket is held rather than skipped (`SymphonyElixir.ClosedPullRequest`). The Code
  Review verdict carries the decision — `SymphonyElixir.CodeReview` asks this module at approve time
  and records the outcome with its reason — and the QA state's own run re-checks it
  (`SymphonyElixir.QaVerification`), so a skipped ticket never starts an agent and every skip is
  auditable in the ticket's ledger.

  A run can have nothing on screen to judge: a `macos_app` pass selected although no changed path
  matches any selected playbook's `paths` (a `qa:macos_app` label on a backend change, say) and the
  ticket has no `## User walkthrough`. Its `macos_app` playbook is then marked `scope: :none`, so
  the QA agent is told up front that building and launching the app are the whole check, and the
  merge stays gated on the app starting (`SymphonyElixir.QaVerification`).

  A `macos_app` playbook with a `live` server (`SymphonyElixir.QaAgent.PlaybookSettings`) is marked
  `live: true` when the pass should run that server on the QA host beside the app: the diff touches
  one of the server's `paths` and the ticket's `## User walkthrough` mentions one of its
  `walkthrough_mentions` (any walkthrough when it lists none). A `qa:live` label marks it live and a
  `qa:fixture` label never does, whatever the diff. A pass not marked live starts no server, and the
  app reads its fixtures only.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.Verification
  alias SymphonyElixir.Walkthrough
  alias SymphonyElixir.Workspace

  @live_label "qa:live"
  @fixture_label "qa:fixture"

  @typedoc """
  Whether the change needs a QA run — and with which playbooks — or skips it, with the recorded
  reason. `:nothing_to_verify` is a head that changes no files: not a docs-only change but no change
  at all (a workspace built from the base branch, a branch whose work already landed), so the
  callers hold the ticket instead of landing it.
  """
  @type decision :: {:run, [Selection.playbook()], String.t()} | {:skip, String.t()} | {:nothing_to_verify, String.t()}

  @doc """
  The decision for `issue`'s change: the paths `sha` (default `HEAD`) changes against the merge
  base of `origin/<base>` in `workspace`. A diff that cannot be read runs QA rather than skipping
  it, so a broken read never smuggles a change past verification.
  """
  @spec decide(Issue.t(), map(), keyword()) :: decision()
  def decide(%Issue{} = issue, settings, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    repo_key = Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)
    sha = Keyword.get(opts, :sha) || "HEAD"

    decision =
      case changed_paths(workspace, repo_key, sha, opts) do
        {:ok, paths} ->
          decision(issue, settings, paths)

        {:error, reason} ->
          {:run, enabled_playbooks(settings), "the changed paths could not be read (#{format_reason(reason)})"}
      end

    log_selection(issue, sha, decision, settings)
    decision
  end

  # One line per decision: the playbooks it runs, and why each other one does not run, which names
  # the setting an off playbook needs (`verification.enabled` or `verification.dev_server`, say).
  defp log_selection(issue, sha, decision, settings) do
    {verdict, selected} =
      case decision do
        {:run, playbooks, _reason} -> {"run", Enum.map(playbooks, & &1.kind)}
        {verdict, reason} -> {"#{verdict} reason=#{inspect(reason)}", []}
      end

    opts = Verification.selection_opts(settings)
    untriggered = for %{kind: kind} <- Selection.playbooks(settings.auto_review, opts), kind not in selected, do: "#{kind}: not triggered"
    off = for {kind, why} <- Selection.unavailable(settings.auto_review, opts), do: "#{kind}: #{why}"

    Logger.info(
      "QA selection issue_id=#{issue.id} issue_identifier=#{issue.identifier} sha=#{sha} decision=#{verdict} " <>
        "playbooks=#{Enum.join(selected, ",")} not_selected=#{inspect(Enum.join(untriggered ++ off, "; "))}"
    )
  end

  @doc """
  The decision for an already-listed set of changed paths. No changed path is nothing to verify,
  whatever the labels say: an empty diff never skips QA into `Merging`.
  """
  @spec decision(Issue.t(), map(), [String.t()]) :: decision()
  def decision(%Issue{}, _settings, []), do: {:nothing_to_verify, "the head changes no files against its base branch"}

  def decision(%Issue{} = issue, settings, paths) when is_list(paths) do
    case Selection.decide(issue, paths, settings.auto_review, Verification.selection_opts(settings)) do
      {:skip, reason} -> {:skip, reason}
      {:run, playbooks} -> run(issue, playbooks, paths)
    end
  end

  defp run(issue, playbooks, paths) do
    {playbooks, live_note} = mark_live(issue, playbooks, paths)

    if nothing_on_screen?(issue, playbooks, paths) do
      {:run, Enum.map(playbooks, &scope_none/1),
       "nothing on screen to judge: the PR changes none of the selected playbooks' paths and the ticket has no `## User walkthrough`, " <>
         "so building and launching the app are the whole check" <> live_note}
    else
      {:run, playbooks, "the change delivers or updates a user journey" <> live_note}
    end
  end

  # Marks the `macos_app` playbook live when its `live` server should run, and says why in the reason.
  defp mark_live(issue, playbooks, paths) do
    Enum.map_reduce(playbooks, "", fn
      %{kind: "macos_app", live_server: live_server} = playbook, note ->
        case live(issue, live_server, paths) do
          {true, why} -> {Map.put(playbook, :live, true), note <> "; the app gets a live server: " <> why}
          {false, why} -> {playbook, note <> "; the app reads fixtures only: " <> why}
        end

      playbook, note ->
        {playbook, note}
    end)
  end

  defp live(issue, live_server, paths) do
    labels = issue |> Issue.label_names() |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    section = Walkthrough.section(issue.description)

    cond do
      @fixture_label in labels -> {false, "the issue has the `#{@fixture_label}` label"}
      @live_label in labels -> {true, "the issue has the `#{@live_label}` label"}
      not server_change?(live_server, paths) -> {false, "the PR changes none of the server's paths"}
      is_nil(section) -> {false, "the ticket has no `## User walkthrough`"}
      not mentions?(section, live_server.walkthrough_mentions) -> {false, "no `## User walkthrough` step names #{words(live_server)}"}
      true -> {true, "the PR changes the server and " <> walkthrough_note(live_server)}
    end
  end

  defp server_change?(live_server, paths),
    do: Enum.any?(paths, fn path -> Enum.any?(live_server.paths, &Selection.glob_match?(path, &1)) end)

  defp mentions?(_section, []), do: true
  defp mentions?(section, words), do: Enum.any?(words, &Regex.match?(~r/\b#{Regex.escape(&1)}\b/iu, section))

  defp words(%{walkthrough_mentions: words}), do: Enum.map_join(words, " or ", &"`#{&1}`")

  defp walkthrough_note(%{walkthrough_mentions: []}), do: "the ticket has a `## User walkthrough`"
  defp walkthrough_note(live_server), do: "the `## User walkthrough` names #{words(live_server)}"

  defp nothing_on_screen?(issue, playbooks, paths) do
    Enum.any?(playbooks, &(&1.kind == "macos_app")) and not Selection.user_walkthrough?(issue) and
      not Enum.any?(paths, fn path -> Enum.any?(playbooks, fn playbook -> Enum.any?(playbook.paths, &Selection.glob_match?(path, &1)) end) end)
  end

  defp scope_none(%{kind: "macos_app"} = playbook), do: Map.put(playbook, :scope, :none)
  defp scope_none(playbook), do: playbook

  @doc "Every enabled playbook, the broad set a run falls back to when the diff cannot be read."
  @spec enabled_playbooks(map()) :: [Selection.playbook()]
  def enabled_playbooks(settings), do: Selection.playbooks(settings.auto_review, Verification.selection_opts(settings))

  @doc """
  The kinds of the enabled playbooks a run did not select: the `macos_app` playbook on a server-only
  diff, say. A walkthrough step only one of them could show is `unprovable` on that run
  (`SymphonyElixir.QaVerification`), and a `qa:<kind>` label on the ticket selects it.
  """
  @spec unselected_playbooks(map(), [Selection.playbook()]) :: [String.t()]
  def unselected_playbooks(settings, selected) do
    kinds = Enum.map(selected, & &1.kind)
    for %{kind: kind} <- enabled_playbooks(settings), kind not in kinds, do: kind
  end

  @doc """
  The paths `sha` changes against the merge base of `origin/<base>` in `workspace`. `opts[:git]`
  overrides the git runner (tests); it is called as `git.(args, cwd)` and returns `{output, status}`.
  """
  @spec changed_paths(Path.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_paths(workspace, repo_key, sha, opts) when is_binary(workspace) do
    git = Keyword.get(opts, :git, &default_git/2)
    base = "origin/" <> Config.base_branch(repo_key)

    with {merge_base, 0} <- git.(["merge-base", base, sha], workspace),
         {output, 0} <- git.(["diff", "--name-only", String.trim(merge_base), sha], workspace) do
      {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
    else
      {output, status} -> {:error, {:git_failed, status, to_string(output)}}
    end
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  # `changed_paths/4` is the only producer of a reason here, and it always names a git failure.
  defp format_reason({:git_failed, status, output}), do: trim_output(status, output)

  defp trim_output(status, output) do
    trimmed = output |> to_string() |> String.trim()
    if trimmed == "", do: "git exited #{status}", else: "git exited #{status}: #{trimmed}"
  end
end
