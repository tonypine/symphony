defmodule SymphonyElixir.QualityGate do
  @moduledoc """
  Issue-scoping quality gate. Runs between `Tracker.fetch_candidate_issues/0`
  and the orchestrator's dispatch loop, asking an LLM to score each candidate
  for agent-readiness on a 1–10 scale.

  Issues that score below the configured pass threshold are either held for
  human clarification or filtered out and surfaced to the orchestrator as
  `skip_entry/0` records.

  ### Caching

  Scores are cached keyed by `{issue.id, issue.updated_at, comment activity}`.
  The cache value also remembers whether a Linear comment has already been
  posted for the current key, so subsequent poll cycles do not re-evaluate or
  re-comment unchanged issues. Editing the issue description or adding a
  non-quality-gate comment invalidates the cache and lets the gate re-score.

  ### Errors

  When the LLM call fails, the cache is *not* updated (so the call is
  retried next poll), and behavior follows `on_error`:

    * `"pass"` (default) — the issue is allowed through; a warning is logged.
    * `"skip"` — the issue is skipped for the cycle; a warning is logged.
  """

  require Logger

  alias SymphonyElixir.{AgentLabels, AuditLog, Config.Schema, Linear.Issue, Secret}

  @anthropic_provider "anthropic"
  @openai_provider "openai"
  @clarification_comment_marker "Symphony quality gate: clarification requested"
  @skip_comment_marker "Symphony quality gate: skipped"
  @workpad_comment_markers AgentLabels.known_workpad_markers()
  @fallback_questions [
    "What specific acceptance criteria should the agent satisfy before opening a PR?",
    "Which files, modules, or product areas should the agent focus on?",
    "What scope boundaries or out-of-scope cases should the agent avoid?"
  ]

  @type cache :: %{optional(String.t()) => cache_entry()}
  @type cache_entry :: %{
          required(:updated_at) => DateTime.t() | nil,
          required(:comment_signature) => String.t() | nil,
          required(:score) => integer() | nil,
          required(:reason) => String.t() | nil,
          required(:passed?) => boolean(),
          required(:awaiting_clarification?) => boolean(),
          required(:questions) => [String.t()],
          required(:rounds_asked) => non_neg_integer(),
          required(:comment_posted?) => boolean(),
          required(:posted_at) => DateTime.t() | nil,
          required(:identifier) => String.t() | nil,
          required(:repo_key) => String.t() | nil,
          required(:title) => String.t() | nil,
          required(:state) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:scored_at) => DateTime.t()
        }

  @type scored_skip :: %{
          required(:kind) => :scored,
          required(:issue) => Issue.t(),
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:repo_key) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:updated_at) => DateTime.t() | nil,
          required(:comment_signature) => String.t() | nil,
          required(:reason) => String.t(),
          required(:score) => integer(),
          optional(:rounds_asked) => non_neg_integer(),
          optional(:max_rounds) => pos_integer(),
          optional(:max_rounds_reached?) => boolean(),
          required(:comment_posted?) => boolean()
        }

  @type error_skip :: %{
          required(:kind) => :error,
          required(:issue) => Issue.t(),
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:repo_key) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:updated_at) => DateTime.t() | nil,
          required(:comment_signature) => String.t() | nil,
          required(:reason) => String.t(),
          required(:error) => term(),
          required(:comment_posted?) => boolean()
        }

  @type clarification_entry :: %{
          required(:kind) => :clarification,
          required(:issue) => Issue.t(),
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:updated_at) => DateTime.t() | nil,
          required(:comment_signature) => String.t() | nil,
          required(:reason) => String.t(),
          required(:score) => integer(),
          required(:questions) => [String.t()],
          required(:rounds_asked) => pos_integer(),
          required(:max_rounds) => pos_integer(),
          required(:pass_threshold) => pos_integer(),
          required(:comment_posted?) => boolean()
        }

  @type skip_entry :: scored_skip() | error_skip()
  @type gate_entry :: skip_entry() | clarification_entry()

  @type result :: %{
          passed: [Issue.t()],
          skipped: [skip_entry()],
          awaiting_clarification: [clarification_entry()],
          cache: cache()
        }

  @doc """
  Filter `issues` through the quality gate. Returns:

      %{passed: [Issue.t()], skipped: [skip_entry()], awaiting_clarification: [clarification_entry()], cache: cache()}

  When the gate is disabled (`config.enabled == false`), every issue passes
  unchanged and the cache is returned untouched.

  Options:

    * `:now` — `%DateTime{}` used to stamp newly-scored cache entries;
      defaults to `DateTime.utc_now/0`.
    * `:provider_module` — override the provider implementation. Used by
      tests to inject a stub.
  """
  def evaluate(issues, config, cache \\ %{}, opts \\ [])

  @spec evaluate([Issue.t()], Schema.QualityGate.t() | nil, cache(), keyword()) :: result()
  def evaluate(issues, %Schema.QualityGate{enabled: true} = config, cache, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    provider_override = Keyword.get(opts, :provider_module)

    {passed_rev, skipped_rev, awaiting_rev, new_cache} =
      Enum.reduce(issues, {[], [], [], cache}, fn issue, {passed, skipped, awaiting, cache_acc} ->
        case evaluate_issue(issue, config, cache_acc, now, provider_override) do
          {:pass, cache_next} ->
            {[issue | passed], skipped, awaiting, cache_next}

          {:skip, entry, cache_next} ->
            {passed, [entry | skipped], awaiting, cache_next}

          {:awaiting_clarification, entry, cache_next} ->
            {passed, skipped, [entry | awaiting], cache_next}
        end
      end)

    %{
      passed: Enum.reverse(passed_rev),
      skipped: Enum.reverse(skipped_rev),
      awaiting_clarification: Enum.reverse(awaiting_rev),
      cache: new_cache
    }
  end

  def evaluate(issues, _config, cache, _opts) do
    %{passed: issues, skipped: [], awaiting_clarification: [], cache: cache}
  end

  @doc """
  Drop cache entries for issues that no longer appear in `issues`. This keeps
  the skipped section bounded as Linear filters change (e.g., issues moved
  to terminal state, reassigned).
  """
  @spec retain_active_issues(cache(), [Issue.t()]) :: cache()
  def retain_active_issues(cache, issues) when is_map(cache) and is_list(issues) do
    active_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: id} when is_binary(id) -> [id]
        _ -> []
      end)
      |> MapSet.new()

    cache
    |> Enum.filter(fn {issue_id, _entry} -> MapSet.member?(active_ids, issue_id) end)
    |> Map.new()
  end

  @doc """
  List cached entries currently classified as skipped, formatted for the
  dashboard's Skipped section. Sorted by most-recently scored first.
  """
  @spec skipped_from_cache(cache()) :: [map()]
  def skipped_from_cache(cache) when is_map(cache) do
    cache
    |> Enum.flat_map(fn {issue_id, entry} ->
      if Map.get(entry, :passed?) == false and Map.get(entry, :awaiting_clarification?) != true do
        [
          %{
            kind: :scored,
            issue_id: issue_id,
            repo_key: Map.get(entry, :repo_key),
            identifier: entry.identifier,
            title: entry.title,
            state: entry.state,
            url: entry.url,
            score: entry.score,
            reason: entry.reason,
            rounds_asked: Map.get(entry, :rounds_asked, 0),
            max_rounds: Map.get(entry, :max_rounds),
            pass_threshold: Map.get(entry, :pass_threshold),
            scored_at: entry.scored_at
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.scored_at, {:desc, DateTime})
  end

  @doc """
  List cached entries currently waiting for human clarification. Sorted by
  most-recently scored first.
  """
  @spec awaiting_clarification_from_cache(cache()) :: [map()]
  def awaiting_clarification_from_cache(cache) when is_map(cache) do
    cache
    |> Enum.flat_map(fn
      {issue_id, %{awaiting_clarification?: true} = entry} ->
        [
          %{
            kind: :clarification,
            issue_id: issue_id,
            repo_key: Map.get(entry, :repo_key),
            identifier: entry.identifier,
            title: entry.title,
            state: entry.state,
            url: entry.url,
            score: entry.score,
            reason: entry.reason,
            rounds_asked: Map.get(entry, :rounds_asked, 0),
            max_rounds: Map.get(entry, :max_rounds),
            pass_threshold: Map.get(entry, :pass_threshold),
            questions: Map.get(entry, :questions, []),
            scored_at: entry.scored_at
          }
        ]

      _ ->
        []
    end)
    |> Enum.sort_by(& &1.scored_at, {:desc, DateTime})
  end

  @doc """
  Mark a skip entry as having had its Linear comment posted in `cache`.

  Used by the orchestrator after it successfully creates the comment, so
  subsequent poll cycles see `comment_posted?: true` for the same
  `updated_at` and do not double-post.

  `posted_at` is stored on the entry so subsequent polls can recognize the
  `updated_at` bump Linear performs on the issue when our own comment is
  created, and avoid re-scoring it. See `cache_freshness/3`.
  """
  @spec mark_comment_posted(cache(), gate_entry(), DateTime.t()) :: cache()
  def mark_comment_posted(cache, %{issue_id: issue_id}, %DateTime{} = posted_at)
      when is_binary(issue_id) do
    case Map.fetch(cache, issue_id) do
      {:ok, entry} ->
        Map.put(cache, issue_id, %{entry | comment_posted?: true, posted_at: posted_at})

      :error ->
        cache
    end
  end

  def mark_comment_posted(cache, _entry, _posted_at), do: cache

  @doc """
  Resolve provider credentials and runtime settings for `config`. Reads the
  API key from the environment so secrets stay out of `WORKFLOW.md`.
  """
  @spec provider_settings(Schema.QualityGate.t()) ::
          {:ok, SymphonyElixir.QualityGate.Provider.settings()} | {:error, term()}
  def provider_settings(%Schema.QualityGate{provider: provider, model: model})
      when is_binary(provider) and is_binary(model) do
    case api_key_for(provider) do
      {:ok, api_key} -> {:ok, %{provider: provider, model: model, api_key: Secret.wrap(api_key)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def provider_settings(_config), do: {:error, :missing_provider_settings}

  @doc """
  Format the body of the Linear comment posted when an issue is skipped.
  """
  @spec skip_comment_body(skip_entry(), Schema.QualityGate.t()) :: String.t()
  def skip_comment_body(
        %{kind: :scored, score: score, reason: reason, max_rounds_reached?: true, rounds_asked: rounds_asked},
        %Schema.QualityGate{} = config
      )
      when is_integer(score) do
    threshold = pass_threshold(config)

    """
    Symphony quality gate: skipped (score #{score} < threshold #{threshold}).

    Asked #{rounds_asked} times; still below pass_threshold. Skipping until description is updated.

    Reason: #{reason}
    """
  end

  def skip_comment_body(%{kind: :scored, score: score, reason: reason}, %Schema.QualityGate{} = config)
      when is_integer(score) do
    threshold = pass_threshold(config)

    """
    Symphony quality gate: skipped (score #{score} < threshold #{threshold}).

    Reason: #{reason}

    To re-queue this issue, edit the description with clearer acceptance
    criteria, tighter scope, or fewer ambiguous markers (e.g. "investigate",
    "explore"). Symphony will silently re-evaluate it on the next poll.
    """
  end

  def skip_comment_body(%{kind: :error, reason: reason}, %Schema.QualityGate{} = config) do
    threshold = pass_threshold(config)

    """
    Symphony quality gate: skipped (LLM call failed; threshold #{threshold}).

    Reason: #{reason}

    To re-queue this issue, edit the description and Symphony will retry
    scoring on the next poll.
    """
  end

  @doc """
  Format the Linear comment posted when Symphony needs clarification before
  dispatch.
  """
  @spec clarification_comment_body(clarification_entry(), Schema.QualityGate.t()) :: String.t()
  def clarification_comment_body(%{score: score, reason: reason, questions: questions, rounds_asked: rounds_asked, max_rounds: max_rounds}, %Schema.QualityGate{} = config) do
    threshold = pass_threshold(config)

    formatted_questions =
      questions
      |> normalize_questions()
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {question, index} -> "#{index}. #{question}" end)

    """
    #{@clarification_comment_marker} (score #{score} < pass_threshold #{threshold}; round #{rounds_asked}/#{max_rounds}).

    Reason: #{reason}

    Questions:
    #{formatted_questions}

    Reply in Linear with 1-2 sentences per question. Symphony will re-evaluate this issue on the next poll.
    """
  end

  defp evaluate_issue(%Issue{id: issue_id, updated_at: updated_at} = issue, config, cache, now, provider_override)
       when is_binary(issue_id) do
    comment_signature = comment_activity_signature(issue)

    case Map.get(cache, issue_id) do
      entry when is_map(entry) ->
        case cache_freshness(entry, updated_at, comment_signature) do
          :current ->
            cached_decision(issue, entry, config, cache, now, provider_override)

          :self_bump ->
            refreshed_entry = %{entry | updated_at: updated_at}
            refreshed_cache = Map.put(cache, issue_id, refreshed_entry)
            cached_decision(issue, refreshed_entry, config, refreshed_cache, now, provider_override)

          :stale ->
            score_and_record(issue, config, cache, now, provider_override)
        end

      _stale_or_missing ->
        score_and_record(issue, config, cache, now, provider_override)
    end
  end

  defp evaluate_issue(issue, _config, cache, _now, _provider_override) do
    Logger.warning("QualityGate received malformed issue=#{inspect(issue)}; passing through")
    {:pass, cache}
  end

  defp cached_decision(_issue, %{passed?: true}, _config, cache, _now, _provider_override), do: {:pass, cache}

  defp cached_decision(issue, %{awaiting_clarification?: true} = entry, _config, cache, _now, _provider_override),
    do: {:awaiting_clarification, build_clarification_entry(issue, entry), cache}

  defp cached_decision(issue, %{passed?: false} = entry, _config, cache, _now, _provider_override),
    do: {:skip, build_skip_entry(issue, entry), cache}

  defp cached_decision(issue, _entry, config, cache, now, provider_override),
    do: score_and_record(issue, config, cache, now, provider_override)

  defp score_and_record(%Issue{} = issue, config, cache, now, provider_override) do
    case provider_settings(config) do
      {:ok, settings} ->
        provider = provider_override || provider_module(settings.provider)
        invoke_provider(issue, config, cache, provider, settings, now)

      {:error, reason} ->
        handle_provider_error(issue, config, cache, reason)
    end
  end

  defp invoke_provider(issue, config, cache, provider_module, settings, now) do
    case provider_module.score(issue, settings) do
      {:ok, %{score: score, reason: reason} = response} ->
        classify_score(issue, config, cache, now, score, reason, Map.get(response, :questions, []))

      {:error, reason} ->
        handle_provider_error(issue, config, cache, reason)
    end
  end

  defp classify_score(issue, config, cache, now, score, reason, questions) when score >= 1 and score <= 10 do
    threshold = pass_threshold(config)

    cond do
      score >= threshold ->
        Logger.info("QualityGate passed issue=#{issue.identifier || issue.id} score=#{score} threshold=#{threshold}")

        cache_next = put_cache(cache, issue, score, reason, true, now)
        {:pass, cache_next}

      clarification_score?(score, config) ->
        maybe_request_clarification(issue, config, cache, now, score, reason, questions)

      true ->
        Logger.info("QualityGate skipped issue=#{issue.identifier || issue.id} score=#{score} threshold=#{threshold} reason=#{AuditLog.redact_for_log(reason)}")

        cache_next = put_cache(cache, issue, score, reason, false, now)
        entry = build_skip_entry(issue, Map.get(cache_next, issue.id))
        {:skip, entry, cache_next}
    end
  end

  defp classify_score(issue, config, cache, _now, score, _reason, _questions) do
    handle_provider_error(issue, config, cache, {:invalid_score, score})
  end

  defp maybe_request_clarification(issue, config, cache, now, score, reason, questions) do
    threshold = pass_threshold(config)
    rounds_asked = prior_rounds_asked(cache, issue.id)
    max_rounds = max_clarification_rounds(config)

    if rounds_asked >= max_rounds do
      Logger.info("QualityGate skipped issue=#{issue.identifier || issue.id} score=#{score} threshold=#{threshold} rounds_asked=#{rounds_asked} reason=#{AuditLog.redact_for_log(reason)}")

      cache_next =
        put_cache(cache, issue, score, reason, false, now,
          rounds_asked: rounds_asked,
          max_rounds: max_rounds,
          pass_threshold: threshold,
          max_rounds_reached?: true
        )

      entry = build_skip_entry(issue, Map.get(cache_next, issue.id))
      {:skip, entry, cache_next}
    else
      next_round = rounds_asked + 1
      normalized_questions = normalize_questions(questions)

      Logger.info("QualityGate awaiting clarification issue=#{issue.identifier || issue.id} score=#{score} threshold=#{threshold} round=#{next_round}/#{max_rounds}")

      cache_next =
        put_cache(cache, issue, score, reason, false, now,
          awaiting_clarification?: true,
          questions: normalized_questions,
          rounds_asked: next_round,
          max_rounds: max_rounds,
          pass_threshold: threshold
        )

      entry = build_clarification_entry(issue, Map.get(cache_next, issue.id))
      {:awaiting_clarification, entry, cache_next}
    end
  end

  defp handle_provider_error(%Issue{} = issue, %Schema.QualityGate{on_error: "skip"}, cache, reason) do
    Logger.warning("QualityGate LLM call failed; on_error=skip issue=#{issue.identifier || issue.id} reason=#{AuditLog.redact_for_log(reason)}")

    {:skip, build_error_skip_entry(issue, reason), cache}
  end

  defp handle_provider_error(%Issue{} = issue, _config, cache, reason) do
    Logger.warning("QualityGate LLM call failed; on_error=pass issue=#{issue.identifier || issue.id} reason=#{AuditLog.redact_for_log(reason)}")

    {:pass, Map.delete(cache, issue.id)}
  end

  defp put_cache(cache, %Issue{} = issue, score, reason, passed?, now, opts \\ []) do
    awaiting_clarification? = Keyword.get(opts, :awaiting_clarification?, false)
    rounds_asked = Keyword.get(opts, :rounds_asked, if(passed?, do: 0, else: prior_rounds_asked(cache, issue.id)))

    Map.put(cache, issue.id, %{
      updated_at: issue.updated_at,
      comment_signature: comment_activity_signature(issue),
      score: score,
      reason: reason,
      passed?: passed?,
      awaiting_clarification?: awaiting_clarification?,
      questions: Keyword.get(opts, :questions, []),
      rounds_asked: rounds_asked,
      max_rounds: Keyword.get(opts, :max_rounds),
      pass_threshold: Keyword.get(opts, :pass_threshold),
      max_rounds_reached?: Keyword.get(opts, :max_rounds_reached?, false),
      comment_posted?: false,
      posted_at: nil,
      repo_key: issue.repo_key,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      url: issue.url,
      scored_at: now
    })
  end

  defp build_skip_entry(%Issue{} = issue, %{score: score, reason: reason} = entry) do
    %{
      kind: :scored,
      issue: issue,
      issue_id: issue.id,
      repo_key: issue.repo_key,
      identifier: issue.identifier,
      url: issue.url,
      updated_at: issue.updated_at,
      comment_signature: Map.get(entry, :comment_signature),
      score: score,
      reason: reason,
      rounds_asked: Map.get(entry, :rounds_asked, 0),
      max_rounds: Map.get(entry, :max_rounds),
      max_rounds_reached?: Map.get(entry, :max_rounds_reached?, false),
      comment_posted?: Map.get(entry, :comment_posted?, false)
    }
  end

  defp build_clarification_entry(%Issue{} = issue, %{score: score, reason: reason} = entry) do
    %{
      kind: :clarification,
      issue: issue,
      issue_id: issue.id,
      repo_key: issue.repo_key,
      identifier: issue.identifier,
      url: issue.url,
      updated_at: issue.updated_at,
      comment_signature: Map.get(entry, :comment_signature),
      score: score,
      reason: reason,
      questions: normalize_questions(Map.get(entry, :questions, [])),
      rounds_asked: Map.get(entry, :rounds_asked, 1),
      max_rounds: Map.get(entry, :max_rounds) || 1,
      pass_threshold: Map.get(entry, :pass_threshold) || 1,
      comment_posted?: Map.get(entry, :comment_posted?, false)
    }
  end

  defp build_error_skip_entry(%Issue{} = issue, error) do
    %{
      kind: :error,
      issue: issue,
      issue_id: issue.id,
      repo_key: issue.repo_key,
      identifier: issue.identifier,
      url: issue.url,
      updated_at: issue.updated_at,
      comment_signature: comment_activity_signature(issue),
      reason: "LLM call failed: #{AuditLog.redact_for_log(error)}",
      error: error,
      comment_posted?: false
    }
  end

  # Window within which a Linear `issue.updated_at` bump is attributed to a
  # comment Symphony itself just posted (Linear bumps `updated_at` on comment
  # creation but with some processing delay; observed ~20s).
  @self_bump_tolerance_seconds 300

  defp cache_freshness(entry, updated_at, comment_signature) when is_map(entry) do
    cond do
      Map.get(entry, :comment_signature) != comment_signature ->
        :stale

      Map.get(entry, :updated_at) == updated_at ->
        :current

      self_bumped?(entry, updated_at) ->
        :self_bump

      true ->
        :stale
    end
  end

  defp self_bumped?(entry, %DateTime{} = new_updated_at) do
    case Map.get(entry, :posted_at) do
      %DateTime{} = posted_at ->
        diff = DateTime.diff(new_updated_at, posted_at, :second)
        diff >= -@self_bump_tolerance_seconds and diff <= @self_bump_tolerance_seconds

      _ ->
        false
    end
  end

  defp self_bumped?(_entry, _new_updated_at), do: false

  defp pass_threshold(%Schema.QualityGate{pass_threshold: threshold}) when is_integer(threshold), do: threshold
  defp pass_threshold(%Schema.QualityGate{min_score: threshold}) when is_integer(threshold), do: threshold

  defp clarification_score?(score, %Schema.QualityGate{clarification_floor: floor} = config)
       when is_integer(score) and is_integer(floor) do
    score >= floor and score < pass_threshold(config)
  end

  defp clarification_score?(_score, _config), do: false

  defp max_clarification_rounds(%Schema.QualityGate{max_clarification_rounds: rounds})
       when is_integer(rounds) and rounds > 0,
       do: rounds

  defp prior_rounds_asked(cache, issue_id) when is_map(cache) and is_binary(issue_id) do
    case Map.get(cache, issue_id) do
      %{rounds_asked: rounds} when is_integer(rounds) and rounds >= 0 -> rounds
      _entry -> 0
    end
  end

  defp normalize_questions(questions) when is_list(questions) do
    normalized =
      questions
      |> Enum.flat_map(fn
        question when is_binary(question) ->
          case String.trim(question) do
            "" -> []
            trimmed -> [trimmed]
          end

        _question ->
          []
      end)
      |> Enum.uniq()
      |> Enum.take(5)

    normalized
    |> fill_fallback_questions()
    |> Enum.take(5)
  end

  defp normalize_questions(_questions), do: @fallback_questions

  defp fill_fallback_questions(questions) when length(questions) >= 3, do: questions

  defp fill_fallback_questions(questions) do
    @fallback_questions
    |> Enum.reject(&(&1 in questions))
    |> Enum.reduce_while(questions, fn fallback, acc ->
      next = acc ++ [fallback]

      if length(next) >= 3 do
        {:halt, next}
      else
        {:cont, next}
      end
    end)
  end

  defp comment_activity_signature(%Issue{comments: comments}) when is_list(comments) do
    comments
    |> Enum.reject(&signature_excluded_comment?/1)
    |> Enum.map(&comment_signature_part/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] ->
        nil

      parts ->
        payload = Enum.join(parts, "\n---\n")

        digest =
          :crypto.hash(:sha256, payload)
          |> Base.encode16(case: :lower)

        "#{length(parts)}:#{digest}"
    end
  end

  defp comment_activity_signature(_issue), do: nil

  defp signature_excluded_comment?(%{body: body}) when is_binary(body) do
    trimmed = String.trim(body)

    String.starts_with?(trimmed, @clarification_comment_marker) or
      String.starts_with?(trimmed, @skip_comment_marker) or
      Enum.any?(@workpad_comment_markers, &String.starts_with?(trimmed, &1))
  end

  defp signature_excluded_comment?(_comment), do: false

  defp comment_signature_part(%{body: body} = comment) when is_binary(body) do
    author = Map.get(comment, :author) || "Unknown"
    created_at = comment_signature_datetime(Map.get(comment, :created_at))
    "#{author}\n#{created_at}\n#{String.trim(body)}"
  end

  defp comment_signature_part(_comment), do: ""

  defp comment_signature_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp comment_signature_datetime(_datetime), do: "unknown"

  defp api_key_for(@anthropic_provider) do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_anthropic_api_key}
    end
  end

  defp api_key_for(@openai_provider) do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_openai_api_key}
    end
  end

  defp api_key_for(provider), do: {:error, {:unsupported_provider, provider}}

  @doc false
  @spec provider_module(String.t()) :: module()
  def provider_module(@anthropic_provider),
    do: Application.get_env(:symphony_elixir, :quality_gate_anthropic_module, SymphonyElixir.QualityGate.Anthropic)

  def provider_module(@openai_provider),
    do: Application.get_env(:symphony_elixir, :quality_gate_openai_module, SymphonyElixir.QualityGate.OpenAI)
end
