defmodule SymphonyElixir.QaAgent.Report do
  @moduledoc """
  Renders and publishes the `## Symphony QA Report` Linear comment.

  Symphony keeps one QA report per issue and rewrites it on every QA pass. This is
  the documented exception to the single-workpad rule: the report is written by
  Symphony, never by an agent, so it cannot collide with the workpad.
  """

  require Logger

  alias SymphonyElixir.{AgentTools, Artifacts, Config, QaAgent, TicketEvents, Tracker}
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketEvents.Event

  @heading "## Symphony QA Report"
  @details_limit 2_000
  @comment_limit 100

  # The verdicts whose report states their reason in place of the agent's summary.
  @reason_verdicts [:skip, :blocked, :inconclusive]

  @finding_states %{open: "open", resolved: "resolved, awaiting QA", reopened: "reopened", confirmed: "confirmed fixed"}

  @extensions %{"image/png" => ".png", "image/jpeg" => ".jpg", "text/plain" => ".txt", "text/markdown" => ".md"}

  @typedoc "Where an artifact the report references is published: its label and its Linear URL (nil when it has none)."
  @type link :: %{label: String.t() | nil, url: String.t() | nil}

  @typedoc "The pass's events `render/1` reads its steps and findings from (`ledger/4`)."
  @type ledger :: %{events: [Event.t()], run_id: String.t(), links: %{String.t() => link()}}

  @doc "The heading that identifies the QA report comment."
  @spec heading() :: String.t()
  def heading, do: @heading

  @doc """
  Renders the report for a QA outcome. `outcome` carries `:verdict` (`:pass`,
  `:fail`, `:blocked`, `:inconclusive` or `:skip`), `:sha`, `:target_state`, and optionally
  `:summary`, `:steps`, `:findings`, `:reason`, `:scope` (`:none` on a pass with nothing on screen
  to judge, which states its reason), `:playbooks`, `:environments` (what the app under test could
  read on a `macos_app` pass with a `live` server, and why: a header line), `:tokens`,
  `:runtime_seconds`, `:follow_ups`, `:verdict_retries`, `:escalated`, `:fix_attempt`/`:max_fix_attempts`
  and `:artifacts` (the files the pass kept, `t:SymphonyElixir.QaAgent.artifacts/0`: a step's
  evidence that is a `qa-evidence/` path the pass kept shows its artifact id beside it).

  A run on the head of a branch also passes `:ref` (the branch the commit heads, in place of a PR),
  `:target_issue` (the identifier of the verification ticket `:target_state` applies to) and
  `:filed` (the tickets filed for failing steps, as `%{identifier, title}` with an optional
  `blocked_by` list of the identifiers each one waits on).

  A QA pass also passes its events (`ledger/4`: `:events`, the ticket's events, `:run_id`, the
  pass's run, and `:links`): its steps are then the pass's step evidence, each with its result, what
  QA saw, the environment it was proved in (`fixture` or `live`, a fact of the event) and its files
  linked to their Linear uploads; its findings are the ones the pass recorded, reopened or confirmed
  (`SymphonyElixir.TicketEvents.findings/1`), each with its state and its files linked. Where the
  pass recorded none (a block, an older pass), `:steps` and `:findings` are rendered as given.

  The epic review (`SymphonyElixir.EpicReview`) also passes `:checks`, its deterministic
  pre-checks as `%{name: atom, status: :ok | :attention, detail: String.t()}`, and so does the QA
  state's pass, with one `%{name: String.t(), status: :pass | :fail | :pending, detail: String.t()}`
  per walkthrough step a named test proves (`SymphonyElixir.QaPreCheck`); they render as a
  `### Pre-checks` section so the issue's history says what ran before the agent did.
  """
  @spec render(map()) :: String.t()
  def render(outcome) when is_map(outcome) do
    [
      @heading,
      "",
      "**Verdict:** #{verdict_label(outcome)} → #{target_label(outcome)}",
      "#{head_label(outcome)}#{meta_suffix(outcome)}",
      environments_line(Map.get(outcome, :environments)),
      summary_block(outcome),
      checks_block(Map.get(outcome, :checks, [])),
      steps_block(steps(outcome)),
      findings_block(findings(outcome)),
      filed_block(Map.get(outcome, :filed, [])),
      "_Symphony rewrites this comment on every QA pass._"
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp verdict_label(%{verdict: :fail, escalated: true}), do: "fail (fix attempts used up; handing over to a human)"

  defp verdict_label(%{verdict: :fail, fix_attempt: attempt, max_fix_attempts: max}) when is_integer(attempt) and is_integer(max),
    do: "fail (fix attempt #{attempt} of #{max})"

  defp verdict_label(%{verdict: :skip}), do: "skipped"
  defp verdict_label(%{verdict: :pass, scope: :none}), do: "pass (nothing on screen to judge; the app built and launched)"
  defp verdict_label(%{verdict: verdict}), do: Atom.to_string(verdict)

  defp target_label(%{target_issue: identifier, target_state: state}) when is_binary(identifier), do: "#{identifier} #{state}"
  defp target_label(outcome), do: outcome.target_state

  defp head_label(%{ref: ref} = outcome) when is_binary(ref), do: "**Commit:** `#{short_sha(outcome)}` (head of `#{ref}`)"
  defp head_label(outcome), do: "**PR head:** `#{short_sha(outcome)}`"

  defp environments_line(environments) when is_binary(environments), do: "**App environments:** " <> environments
  defp environments_line(_environments), do: nil

  defp short_sha(outcome), do: String.slice(outcome.sha || "", 0, 12)

  defp meta_suffix(outcome) do
    [
      playbooks_meta(Map.get(outcome, :playbooks, [])),
      runtime_meta(Map.get(outcome, :runtime_seconds)),
      tokens_meta(Map.get(outcome, :tokens)),
      follow_ups_meta(Map.get(outcome, :follow_ups)),
      verdict_retries_meta(Map.get(outcome, :verdict_retries))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(&(" · " <> &1))
  end

  defp playbooks_meta([]), do: nil
  defp playbooks_meta(kinds), do: "playbooks: " <> Enum.join(kinds, ", ")

  defp runtime_meta(seconds) when is_integer(seconds) and seconds > 0, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp runtime_meta(_seconds), do: nil

  defp tokens_meta(%{total_tokens: total}) when is_integer(total) and total > 0, do: "#{total} tokens"
  defp tokens_meta(_tokens), do: nil

  defp follow_ups_meta(1), do: "verdict after 1 follow-up"
  defp follow_ups_meta(count) when is_integer(count) and count > 1, do: "verdict after #{count} follow-ups"
  defp follow_ups_meta(_count), do: nil

  defp verdict_retries_meta(1), do: "pass run again once after a missing verdict"
  defp verdict_retries_meta(_count), do: nil

  defp summary_block(outcome) do
    text =
      case outcome do
        %{verdict: verdict, reason: reason} when verdict in @reason_verdicts and is_binary(reason) -> "Reason: " <> reason
        %{verdict: :pass, scope: :none, reason: reason} when is_binary(reason) -> scope_none_text(reason, Map.get(outcome, :summary))
        _outcome -> Map.get(outcome, :summary)
      end

    if is_binary(text) and String.trim(text) != "", do: "\n" <> String.trim(text) <> "\n", else: ""
  end

  defp scope_none_text(reason, summary) when is_binary(summary) and summary != "", do: "Why nothing was judged on screen: #{reason}\n\n#{summary}"
  defp scope_none_text(reason, _summary), do: "Why nothing was judged on screen: #{reason}"

  defp checks_block([]), do: nil

  defp checks_block(checks) do
    Enum.join(["### Pre-checks", "" | Enum.map(checks, &check_line/1)], "\n") <> "\n"
  end

  defp check_line(%{status: status, name: name, detail: detail}) do
    "- **#{status}** #{name}: #{detail}"
  end

  # The pass's step evidence, else the steps as given.
  defp steps(%{events: events, run_id: run_id} = outcome) when is_list(events) do
    links = Map.get(outcome, :links, %{})

    case Enum.map(pass_steps(events, run_id), &ledger_step(&1, links)) do
      [] -> given_steps(outcome)
      steps -> steps
    end
  end

  defp steps(outcome), do: given_steps(outcome)

  defp given_steps(outcome) do
    artifacts = Map.get(outcome, :artifacts)

    for step <- Map.get(outcome, :steps, []) do
      %{
        name: step.name,
        status: step.status,
        details: Map.get(step, :details) || "",
        environment: Map.get(step, :environment),
        entries: Enum.map(Map.get(step, :evidence, []), &evidence_entry(&1, artifacts))
      }
    end
  end

  defp ledger_step(%Event{payload: payload, artifacts: ids}, links) do
    %{
      name: payload.step,
      status: Map.get(payload, :status) || "noted",
      details: Map.get(payload, :details) || "",
      environment: Map.get(payload, :environment),
      entries: Enum.map(ids, &artifact_entry(&1, links)) ++ Map.get(payload, :links, [])
    }
  end

  # The evidence a QA pass recorded per step (`SymphonyElixir.QaVerification`), oldest first.
  defp pass_steps(events, run_id) do
    for %Event{type: "evidence", run_id: ^run_id, payload: %{step: step}} = event <- events, is_binary(step), do: event
  end

  # The findings the pass recorded or reopened, with where each stands, and the ones it confirmed.
  defp pass_findings(events, run_id) do
    events
    |> TicketEvents.findings()
    |> Enum.flat_map(fn entry ->
      cond do
        ran?(entry.reopened_by, run_id) -> [{entry.reopened_by, entry.state}]
        ran?(entry.finding, run_id) -> [{entry.finding, entry.state}]
        ran?(entry.confirmation, run_id) -> [{entry.finding, :confirmed}]
        true -> []
      end
    end)
  end

  defp ran?(%Event{run_id: run_id}, run_id) when is_binary(run_id), do: true
  defp ran?(_event, _run_id), do: false

  defp steps_block([]), do: nil

  defp steps_block(steps) do
    lines = Enum.map(steps, &step_lines/1)
    Enum.join(["### Steps", "" | lines], "\n") <> "\n"
  end

  defp step_lines(step) do
    notes =
      case Enum.reject([environment_note(step.environment), evidence_note(step.entries)], &is_nil/1) do
        [] -> ""
        notes -> " (" <> Enum.join(notes, "; ") <> ")"
      end

    head = "- **#{step_status(step.status)}** #{step.name}#{notes}"

    case String.trim(step.details) do
      "" -> head
      details -> head <> "\n\n  ```text\n" <> indent(truncate(details)) <> "\n  ```\n"
    end
  end

  defp environment_note("live"), do: "proved on the live server"
  defp environment_note("fixture"), do: "proved on the fixtures"
  defp environment_note(_environment), do: nil

  defp evidence_note([]), do: nil
  defp evidence_note(entries), do: "evidence: " <> Enum.join(entries, ", ")

  # An artifact the report references links to its Linear upload; one that has none yet names the
  # file and its artifact id.
  defp artifact_entry(id, links) do
    case Map.get(links, id) do
      %{url: url} = link when is_binary(url) -> "[#{Path.basename(link.label || String.slice(id, 0, 12))}](#{url})"
      %{label: label} when is_binary(label) -> "#{label} (artifact `#{id}`)"
      _none -> "artifact `#{id}`"
    end
  end

  defp step_status("unprovable"), do: "unprovable here"
  defp step_status(status), do: status

  # A Linear URL stays as it is: the upload is what the reader opens.
  defp evidence_entry(entry, artifacts) do
    case QaAgent.evidence_artifact(artifacts, entry) do
      id when is_binary(id) -> if String.starts_with?(entry, ["http://", "https://"]), do: entry, else: "#{entry} (artifact `#{id}`)"
      nil -> entry
    end
  end

  # The pass's findings, each with its state and its files, else the findings as given.
  defp findings(%{events: events, run_id: run_id} = outcome) when is_list(events) do
    links = Map.get(outcome, :links, %{})

    case Enum.map(pass_findings(events, run_id), &finding_line(&1, links)) do
      [] -> Map.get(outcome, :findings, [])
      lines -> lines
    end
  end

  defp findings(outcome), do: Map.get(outcome, :findings, [])

  defp finding_line({%Event{payload: payload, artifacts: ids}, state}, links) do
    evidence =
      case ids do
        [] -> ""
        ids -> " · evidence: " <> Enum.map_join(ids, ", ", &artifact_entry(&1, links))
      end

    "#{payload.description} · **#{Map.fetch!(@finding_states, state)}**#{evidence}"
  end

  defp findings_block([]), do: nil
  defp findings_block(findings), do: Enum.join(["### Findings", "" | Enum.map(findings, &("- " <> &1))], "\n") <> "\n"

  defp filed_block([]), do: nil

  defp filed_block(filed) do
    Enum.join(["### Filed tickets", "" | Enum.map(filed, &"- #{&1.identifier} #{&1.title}#{blocked_by_suffix(&1)}")], "\n") <> "\n"
  end

  defp blocked_by_suffix(%{blocked_by: [_ | _] = blocked_by}), do: " (blocked by #{Enum.join(blocked_by, ", ")})"
  defp blocked_by_suffix(_ticket), do: ""

  defp truncate(text) when byte_size(text) > @details_limit, do: binary_part(text, 0, @details_limit) <> "\n[... truncated ...]"
  defp truncate(text), do: text

  defp indent(text), do: text |> String.replace("```", "'''") |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  @doc """
  The pass's events for `render/1`: the ticket's `events`, the pass's `run_id`, and where each file
  its steps and findings reference is published (`t:link/0`). A file already uploaded to Linear
  (its `linear_url` projection, `SymphonyElixir.Artifacts`) is linked as it is. On a Linear
  tracker, one not uploaded yet is uploaded once, through the same attach path the QA agent's
  `linear_attach_file` uses, and its URL kept as its projection, so a later pass links it without
  uploading it again. An upload that fails is logged and the file named by its artifact id.
  """
  @spec ledger(Issue.t(), [Event.t()], String.t(), keyword()) :: ledger()
  def ledger(%Issue{} = issue, events, run_id, opts) when is_list(events) and is_binary(run_id) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)
    upload? = settings.tracker.kind == "linear"

    ids =
      (pass_steps(events, run_id) ++ Enum.map(pass_findings(events, run_id), &elem(&1, 0)))
      |> Enum.flat_map(& &1.artifacts)
      |> Enum.uniq()

    %{events: events, run_id: run_id, links: Map.new(ids, &{&1, artifact_link(issue, &1, upload?, opts)})}
  end

  @doc """
  Where the artifact `id` is published (`t:link/0`): its `linear_url` projection when it has one;
  else, with `upload?`, its URL once uploaded to `issue` on Linear (kept as its projection, so it
  is uploaded once); else no URL. The QA report and the workpad's Validation
  (`SymphonyElixir.Workpad.Projection`) link a file this way.
  """
  @spec artifact_link(Issue.t(), String.t(), boolean(), keyword()) :: link()
  def artifact_link(issue, id, upload?, opts) do
    case Artifacts.get(id) do
      {:ok, %{projections: %{linear_url: url}} = artifact} when is_binary(url) -> %{label: artifact.label, url: url}
      {:ok, artifact} when upload? -> %{label: artifact.label, url: upload(issue, artifact, opts)}
      {:ok, artifact} -> %{label: artifact.label, url: nil}
      {:error, _reason} -> %{label: nil, url: nil}
    end
  end

  # The stored file is copied under its own name into a folder of its own, which is the attach
  # path's workspace, so the upload carries the name and type the agent's evidence had.
  defp upload(issue, artifact, opts) do
    dir = Path.join(System.tmp_dir!(), "symphony-qa-report-#{System.unique_integer([:positive])}")

    try do
      with {:ok, source} <- Artifacts.path(artifact.id),
           :ok <- File.mkdir_p(dir),
           path = Path.join(dir, upload_name(artifact)),
           :ok <- File.cp(source, path),
           {:ok, response} <- AgentTools.Linear.attach_file(%{issue: issue, workspace: dir}, path, nil, Keyword.take(opts, [:linear_client, :upload_client, :settings])),
           url when is_binary(url) <- get_in(response, ["data", "attachmentCreate", "attachment", "url"]),
           {:ok, _artifact} <- Artifacts.put_projection(artifact.id, :linear_url, url) do
        url
      else
        error ->
          Logger.warning("Could not upload artifact #{artifact.id} for the QA report of #{issue.identifier || issue.id}: #{inspect(error)}")
          nil
      end
    after
      File.rm_rf(dir)
    end
  end

  # The file's own name, else its short id with the extension of its type.
  defp upload_name(artifact) do
    name = artifact.label && artifact.label |> Path.basename() |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    if name in [nil, "", ".", ".."], do: String.slice(artifact.id, 0, 12) <> Map.get(@extensions, artifact.mime, ""), else: name
  end

  @doc """
  Creates the QA report comment, or rewrites the existing one in place on Linear.
  Other trackers get a new comment. `opts[:heading]` names another Symphony-written comment
  to rewrite the same way.
  """
  @spec publish(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def publish(%Issue{id: issue_id} = issue, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)
    heading = Keyword.get(opts, :heading, @heading)

    if settings.tracker.kind == "linear",
      do: publish_linear(issue, body, heading, Keyword.take(opts, [:linear_client, :settings])),
      else: Tracker.create_comment(issue_id, body)
  end

  defp publish_linear(issue, body, heading, opts) do
    with_linear_comment(issue, heading, opts, fn
      context, nil -> ok(AgentTools.Linear.add_comment(context, body, opts))
      context, comment_id -> ok(AgentTools.Linear.update_comment(context, comment_id, body, opts))
    end)
  end

  # Calls `fun` with the comment that starts with `heading`, or `nil` when there is none. The
  # comment is recorded as this caller's own, so it may be edited.
  defp with_linear_comment(issue, heading, opts, fun) do
    {:ok, registry} = CommentRegistry.start_link()

    try do
      context = %{issue: issue, comment_registry: registry}

      with {:ok, comments} <- AgentTools.Linear.get_comments(context, @comment_limit, opts) do
        case Enum.find(comments, &report_comment?(&1, heading)) do
          %{"id" => comment_id} ->
            CommentRegistry.record(registry, comment_id)
            fun.(context, comment_id)

          nil ->
            fun.(context, nil)
        end
      end
    after
      Agent.stop(registry)
    end
  end

  defp ok({:ok, _response}), do: :ok
  defp ok({:error, reason}), do: {:error, reason}

  defp report_comment?(%{"id" => id, "body" => body}, heading) when is_binary(id) and is_binary(body) do
    body
    |> String.trim()
    |> String.replace_prefix("<linear_issue_comment_body>", "")
    |> String.trim_leading()
    |> String.starts_with?(heading)
  end

  defp report_comment?(_comment, _heading), do: false
end
