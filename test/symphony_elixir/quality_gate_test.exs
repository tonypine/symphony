defmodule SymphonyElixir.QualityGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.QualityGate, as: QualityGateConfig
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QualityGate
  alias SymphonyElixir.Secret

  defmodule StubProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(issue, _settings) do
      results = Process.get(:quality_gate_stub_results, %{})

      case Map.get(results, issue.id) do
        nil -> {:ok, %{score: 8, reason: "default ok"}}
        result -> result
      end
    end
  end

  defmodule SeeingProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(issue, _settings) do
      send(self(), {:scored_comments, issue.comments})
      {:ok, %{score: 9, reason: "ok"}}
    end
  end

  defmodule ErroringProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:error, :stub_boom}
  end

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
    System.put_env("OPENAI_API_KEY", "test-openai-key")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
    end)

    :ok
  end

  describe "evaluate/4 disabled" do
    test "returns all issues unchanged when config is disabled" do
      issues = [issue("ID-1"), issue("ID-2")]
      config = %QualityGateConfig{enabled: false, min_score: 6}

      assert %{passed: ^issues, skipped: [], cache: cache} =
               QualityGate.evaluate(issues, config, %{})

      assert cache == %{}
    end

    test "returns all issues unchanged when config is nil" do
      issues = [issue("ID-1")]

      assert %{passed: ^issues, skipped: [], cache: %{}} =
               QualityGate.evaluate(issues, nil, %{})
    end
  end

  describe "evaluate/4 enabled" do
    test "passes issues that meet the threshold and skips those below" do
      issues = [issue("ID-1"), issue("ID-2")]
      config = config_enabled(min_score: 6)

      Process.put(:quality_gate_stub_results, %{
        "ID-1" => {:ok, %{score: 9, reason: "clear scope"}},
        "ID-2" => {:ok, %{score: 3, reason: "vague"}}
      })

      result =
        QualityGate.evaluate(issues, config, %{},
          provider_module: StubProvider,
          now: DateTime.utc_now()
        )

      assert [%Issue{id: "ID-1"}] = result.passed

      assert [%{kind: :scored, issue_id: "ID-2", score: 3, reason: "vague", comment_posted?: false}] =
               result.skipped

      assert %{passed?: true, score: 9} = Map.get(result.cache, "ID-1")
      assert %{passed?: false, score: 3, comment_posted?: false} = Map.get(result.cache, "ID-2")
    end

    test "treats min_score as inclusive (score == threshold passes)" do
      config = config_enabled(min_score: 6)
      Process.put(:quality_gate_stub_results, %{"ID-X" => {:ok, %{score: 6, reason: "exactly"}}})

      result = QualityGate.evaluate([issue("ID-X")], config, %{}, provider_module: StubProvider)

      assert [%Issue{id: "ID-X"}] = result.passed
      assert result.skipped == []
    end

    test "keeps legacy min_score behavior when clarification_floor is unset" do
      config = config_enabled(min_score: 6)
      Process.put(:quality_gate_stub_results, %{"ID-LEGACY" => {:ok, %{score: 5, reason: "almost"}}})

      result = QualityGate.evaluate([issue("ID-LEGACY")], config, %{}, provider_module: StubProvider)

      assert result.passed == []
      assert result.awaiting_clarification == []
      assert [%{kind: :scored, score: 5, reason: "almost"}] = result.skipped
      assert %{awaiting_clarification?: false, rounds_asked: 0} = Map.fetch!(result.cache, "ID-LEGACY")
    end

    test "holds mid-band issues for clarification when clarification_floor is set" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)

      Process.put(:quality_gate_stub_results, %{
        "ID-MID" =>
          {:ok,
           %{
             score: 5,
             reason: "missing acceptance criteria",
             questions: [
               "What should the agent verify before opening a PR?",
               "Which module owns this behavior?",
               "What should stay out of scope?"
             ]
           }}
      })

      result = QualityGate.evaluate([issue("ID-MID")], config, %{}, provider_module: StubProvider)

      assert result.passed == []
      assert result.skipped == []

      assert [
               %{
                 kind: :clarification,
                 issue_id: "ID-MID",
                 score: 5,
                 reason: "missing acceptance criteria",
                 rounds_asked: 1,
                 max_rounds: 2,
                 pass_threshold: 6,
                 comment_posted?: false,
                 questions: questions
               }
             ] = result.awaiting_clarification

      assert length(questions) == 3
      assert "Which module owns this behavior?" in questions

      assert %{
               passed?: false,
               awaiting_clarification?: true,
               rounds_asked: 1,
               comment_posted?: false
             } = Map.fetch!(result.cache, "ID-MID")
    end

    test "comment activity invalidates cached clarification and allows a passing re-score" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      initial_issue = issue("ID-REPLY")

      Process.put(:quality_gate_stub_results, %{
        "ID-REPLY" =>
          {:ok,
           %{
             score: 5,
             reason: "needs answer",
             questions: ["What is done?", "Where is it?", "What is excluded?"]
           }}
      })

      first = QualityGate.evaluate([initial_issue], config, %{}, provider_module: StubProvider)
      assert [%{rounds_asked: 1}] = first.awaiting_clarification

      answered_issue =
        issue("ID-REPLY",
          comments: [
            %{author: "Operator", body: "Acceptance criteria are now clear.", created_at: ~U[2026-05-05 04:00:00Z]}
          ]
        )

      Process.put(:quality_gate_stub_results, %{"ID-REPLY" => {:ok, %{score: 8, reason: "clear now"}}})

      second = QualityGate.evaluate([answered_issue], config, first.cache, provider_module: StubProvider)

      assert [%Issue{id: "ID-REPLY"}] = second.passed
      assert second.skipped == []
      assert second.awaiting_clarification == []
      assert %{passed?: true, awaiting_clarification?: false, rounds_asked: 0, reason: "clear now"} = Map.fetch!(second.cache, "ID-REPLY")
    end

    test "an Inbox answer to the gate's Question re-scores the ticket with the answer in its comments" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      Process.put(:quality_gate_stub_results, %{"ID-INBOX" => {:ok, %{score: 5, reason: "needs answer", questions: ["What is done?"]}}})
      first = QualityGate.evaluate([issue("ID-INBOX")], config, %{}, provider_module: StubProvider, now: ~U[2026-05-05 03:01:00Z])
      assert [%{rounds_asked: 1}] = first.awaiting_clarification

      # The same answers keep the cache: nothing is scored again.
      Process.put(:quality_gate_stub_results, %{"ID-INBOX" => {:ok, %{score: 8, reason: "clear now"}}})
      unchanged = QualityGate.evaluate([issue("ID-INBOX")], config, first.cache, provider_module: StubProvider, answers: %{"ID-INBOX" => []})
      assert [%{rounds_asked: 1}] = unchanged.awaiting_clarification

      answer = %{text: "Done means the export runs nightly.", option: nil, at: ~U[2026-05-05 03:05:00Z]}

      second =
        QualityGate.evaluate([issue("ID-INBOX")], config, first.cache,
          provider_module: StubProvider,
          answers: %{"ID-INBOX" => [answer]},
          now: ~U[2026-05-05 03:06:00Z]
        )

      assert [%Issue{id: "ID-INBOX", comments: []}] = second.passed
      assert %{passed?: true, reason: "clear now"} = Map.fetch!(second.cache, "ID-INBOX")

      # The answer reads as a comment the provider sees, and it is part of the cache key.
      third = QualityGate.evaluate([issue("ID-INBOX")], config, second.cache, provider_module: StubProvider, answers: %{"ID-INBOX" => [answer]})
      assert [%Issue{id: "ID-INBOX"}] = third.passed
      assert third.cache == second.cache
    end

    test "the provider reads an Inbox answer as a comment after the issue's own" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4)
      answer = %{text: "Only the export module.", option: nil, at: ~U[2026-05-05 03:05:00Z]}

      for comments <- [[%{author: "Operator", body: "Hi", created_at: nil}], :unknown] do
        seen = %{issue("ID-SEE") | comments: comments}
        QualityGate.evaluate([seen], config, %{}, provider_module: SeeingProvider, answers: %{"ID-SEE" => [answer]})
        assert_received {:scored_comments, scored}
        assert %{author: "Director (Symphony Inbox)", body: "Answer to the quality gate's questions: Only the export module."} = List.last(scored)
      end
    end

    test "Start it as it is lets the ticket through without scoring it, once only after the last scoring" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      Process.put(:quality_gate_stub_results, %{"ID-START" => {:ok, %{score: 5, reason: "needs answer", questions: ["What is done?"]}}})
      first = QualityGate.evaluate([issue("ID-START")], config, %{}, provider_module: StubProvider, now: ~U[2026-05-05 03:01:00Z])

      start = %{text: "Start it as it is", option: :start, at: ~U[2026-05-05 03:05:00Z]}

      second =
        QualityGate.evaluate([issue("ID-START")], config, first.cache,
          provider_module: StubProvider,
          answers: %{"ID-START" => [start]},
          now: ~U[2026-05-05 03:06:00Z]
        )

      assert [%Issue{id: "ID-START"}] = second.passed
      assert %{passed?: true, score: nil, reason: "Started as it is by the Director's answer"} = Map.fetch!(second.cache, "ID-START")

      # An edit after that pick is scored as usual: the pick is older than the last scoring.
      edited = issue("ID-START", updated_at: ~U[2026-05-05 05:00:00Z])
      third = QualityGate.evaluate([edited], config, second.cache, provider_module: StubProvider, answers: %{"ID-START" => [start]})
      assert [%{rounds_asked: 1}] = third.awaiting_clarification

      # With no cache entry at all, the pick still lets it through.
      fresh = QualityGate.evaluate([issue("ID-START")], config, %{}, provider_module: StubProvider, answers: %{"ID-START" => [start]})
      assert [%Issue{id: "ID-START"}] = fresh.passed

      # A malformed answers option reads as none.
      none = QualityGate.evaluate([issue("ID-START")], config, %{}, provider_module: StubProvider, answers: :malformed)
      assert [%{rounds_asked: 1}] = none.awaiting_clarification
    end

    test "quality gate comments do not invalidate cached clarification by themselves" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)

      cached_issue =
        issue("ID-SELF",
          comments: [
            %{
              author: "Symphony",
              body: "Symphony quality gate: clarification requested (score 5 < pass_threshold 6; round 1/2).",
              created_at: ~U[2026-05-05 04:00:00Z]
            }
          ]
        )

      cache = %{
        "ID-SELF" => %{
          updated_at: cached_issue.updated_at,
          comment_signature: nil,
          score: 5,
          reason: "cached clarification",
          passed?: false,
          awaiting_clarification?: true,
          questions: ["What is done?", "Where is it?", "What is excluded?"],
          rounds_asked: 1,
          max_rounds: 2,
          pass_threshold: 6,
          comment_posted?: true,
          posted_at: nil,
          identifier: "ACME-ID-SELF",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ID-SELF",
          scored_at: ~U[2026-05-05 03:00:00Z]
        }
      }

      Process.put(:quality_gate_stub_results, %{"ID-SELF" => {:ok, %{score: 9, reason: "should not be called"}}})

      result = QualityGate.evaluate([cached_issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert [%{reason: "cached clarification", comment_posted?: true}] = result.awaiting_clarification
    end

    test "Linear bumping issue.updated_at after Symphony's own comment does not invalidate the cache" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      cached_updated_at = ~U[2026-05-05 03:00:00Z]
      posted_at = ~U[2026-05-05 04:00:00Z]
      bumped_updated_at = ~U[2026-05-05 04:00:22Z]

      symphony_comment = %{
        author: "Symphony",
        body: "Symphony quality gate: clarification requested (score 5 < pass_threshold 6; round 1/2).",
        created_at: posted_at
      }

      bumped_issue =
        issue("ID-BUMP",
          comments: [symphony_comment],
          updated_at: bumped_updated_at
        )

      cache = %{
        "ID-BUMP" => %{
          updated_at: cached_updated_at,
          comment_signature: nil,
          score: 5,
          reason: "cached clarification",
          passed?: false,
          awaiting_clarification?: true,
          questions: ["What is done?", "Where is it?", "What is excluded?"],
          rounds_asked: 1,
          max_rounds: 2,
          pass_threshold: 6,
          comment_posted?: true,
          posted_at: posted_at,
          identifier: "ACME-ID-BUMP",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ID-BUMP",
          scored_at: cached_updated_at
        }
      }

      Process.put(:quality_gate_stub_results, %{"ID-BUMP" => {:ok, %{score: 9, reason: "should not be called"}}})

      result = QualityGate.evaluate([bumped_issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert result.skipped == []
      assert [%{reason: "cached clarification", rounds_asked: 1, comment_posted?: true}] = result.awaiting_clarification
      assert Map.get(result.cache, "ID-BUMP").updated_at == bumped_updated_at
      assert Map.get(result.cache, "ID-BUMP").posted_at == posted_at
    end

    test "an updated_at bump well outside the self-bump window still re-scores" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      cached_updated_at = ~U[2026-05-05 03:00:00Z]
      posted_at = ~U[2026-05-05 04:00:00Z]
      far_future_updated_at = ~U[2026-05-05 04:30:00Z]

      edited_issue = issue("ID-EDIT", updated_at: far_future_updated_at)

      cache = %{
        "ID-EDIT" => %{
          updated_at: cached_updated_at,
          comment_signature: nil,
          score: 5,
          reason: "cached clarification",
          passed?: false,
          awaiting_clarification?: true,
          questions: ["q1", "q2", "q3"],
          rounds_asked: 1,
          max_rounds: 2,
          pass_threshold: 6,
          comment_posted?: true,
          posted_at: posted_at,
          identifier: "ACME-ID-EDIT",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ID-EDIT",
          scored_at: cached_updated_at
        }
      }

      Process.put(:quality_gate_stub_results, %{"ID-EDIT" => {:ok, %{score: 8, reason: "rescored"}}})

      result = QualityGate.evaluate([edited_issue], config, cache, provider_module: StubProvider)

      assert [%Issue{id: "ID-EDIT"}] = result.passed
      assert Map.get(result.cache, "ID-EDIT").reason == "rescored"
    end

    test "a non-DateTime updated_at value still invalidates the cached entry" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      cached_updated_at = ~U[2026-05-05 03:00:00Z]
      edited_issue = issue("ID-NON-DATETIME", updated_at: "2026-05-05T04:00:00Z")

      cache = %{
        "ID-NON-DATETIME" => %{
          updated_at: cached_updated_at,
          comment_signature: nil,
          score: 5,
          reason: "cached clarification",
          passed?: false,
          awaiting_clarification?: true,
          questions: ["q1", "q2", "q3"],
          rounds_asked: 1,
          max_rounds: 2,
          pass_threshold: 6,
          comment_posted?: true,
          posted_at: ~U[2026-05-05 04:00:00Z],
          identifier: "ACME-ID-NON-DATETIME",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ID-NON-DATETIME",
          scored_at: cached_updated_at
        }
      }

      Process.put(:quality_gate_stub_results, %{"ID-NON-DATETIME" => {:ok, %{score: 8, reason: "rescored"}}})

      result = QualityGate.evaluate([edited_issue], config, cache, provider_module: StubProvider)

      assert [%Issue{id: "ID-NON-DATETIME"}] = result.passed
      assert Map.get(result.cache, "ID-NON-DATETIME").reason == "rescored"
    end

    test "a new human comment within the self-bump window still re-scores" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      cached_updated_at = ~U[2026-05-05 03:00:00Z]
      posted_at = ~U[2026-05-05 04:00:00Z]
      bumped_updated_at = ~U[2026-05-05 04:00:25Z]

      bumped_issue =
        issue("ID-HUMAN",
          comments: [
            %{author: "Reviewer", body: "Quick note from a human", created_at: ~U[2026-05-05 04:00:15Z]}
          ],
          updated_at: bumped_updated_at
        )

      cache = %{
        "ID-HUMAN" => %{
          updated_at: cached_updated_at,
          comment_signature: nil,
          score: 5,
          reason: "cached clarification",
          passed?: false,
          awaiting_clarification?: true,
          questions: ["q1", "q2", "q3"],
          rounds_asked: 1,
          max_rounds: 2,
          pass_threshold: 6,
          comment_posted?: true,
          posted_at: posted_at,
          identifier: "ACME-ID-HUMAN",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ID-HUMAN",
          scored_at: cached_updated_at
        }
      }

      Process.put(:quality_gate_stub_results, %{"ID-HUMAN" => {:ok, %{score: 7, reason: "answered"}}})

      result = QualityGate.evaluate([bumped_issue], config, cache, provider_module: StubProvider)

      assert [%Issue{id: "ID-HUMAN"}] = result.passed
      assert Map.get(result.cache, "ID-HUMAN").reason == "answered"
    end

    test "falls through to skip after max clarification rounds" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)

      cache = %{
        "ID-CAP" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          comment_signature: "old",
          score: 5,
          reason: "still vague",
          passed?: false,
          awaiting_clarification?: true,
          questions: ["What is done?", "Where is it?", "What is excluded?"],
          rounds_asked: 2,
          max_rounds: 2,
          pass_threshold: 6,
          comment_posted?: true,
          identifier: "ACME-CAP",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ID-CAP",
          scored_at: ~U[2026-05-05 03:00:00Z]
        }
      }

      issue =
        issue("ID-CAP",
          comments: [%{author: "Operator", body: "Still not enough detail.", created_at: ~U[2026-05-05 05:00:00Z]}]
        )

      Process.put(:quality_gate_stub_results, %{"ID-CAP" => {:ok, %{score: 5, reason: "still vague"}}})

      result = QualityGate.evaluate([issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert result.awaiting_clarification == []
      assert [%{kind: :scored, score: 5, rounds_asked: 2, max_rounds_reached?: true}] = result.skipped
    end

    test "scores below clarification_floor still skip without questions" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4)
      Process.put(:quality_gate_stub_results, %{"ID-LOW" => {:ok, %{score: 3, reason: "too vague"}}})

      result = QualityGate.evaluate([issue("ID-LOW")], config, %{}, provider_module: StubProvider)

      assert result.passed == []
      assert result.awaiting_clarification == []
      assert [%{kind: :scored, score: 3, reason: "too vague"}] = result.skipped
    end

    test "invalid provider scores follow on_error" do
      config = config_enabled(on_error: "skip")

      Process.put(:quality_gate_stub_results, %{
        "ID-BAD-SCORE" => {:ok, %{score: "bad", reason: "not numeric"}}
      })

      result = QualityGate.evaluate([issue("ID-BAD-SCORE")], config, %{}, provider_module: StubProvider)

      assert result.passed == []
      assert [%{kind: :error, error: {:invalid_score, "bad"}, reason: reason}] = result.skipped
      assert reason =~ "invalid_score"
      assert result.cache == %{}
    end

    test "malformed current cache entries are re-scored" do
      config = config_enabled(min_score: 6)
      cached_issue = issue("ID-WEIRD-CACHE")

      cache = %{
        "ID-WEIRD-CACHE" => %{
          updated_at: cached_issue.updated_at,
          comment_signature: nil
        }
      }

      Process.put(:quality_gate_stub_results, %{
        "ID-WEIRD-CACHE" => {:ok, %{score: 8, reason: "rescored"}}
      })

      result = QualityGate.evaluate([cached_issue], config, cache, provider_module: StubProvider)

      assert [%Issue{id: "ID-WEIRD-CACHE"}] = result.passed
      assert %{score: 8, reason: "rescored", passed?: true} = Map.fetch!(result.cache, "ID-WEIRD-CACHE")
    end

    test "normalizes malformed clarification questions with deterministic fallbacks" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4)

      Process.put(:quality_gate_stub_results, %{
        "ID-FEW-QUESTIONS" =>
          {:ok,
           %{
             score: 5,
             reason: "needs detail",
             questions: [" Which file should change? ", "", 42, "Which file should change?"]
           }},
        "ID-BAD-QUESTIONS" =>
          {:ok,
           %{
             score: 5,
             reason: "needs detail",
             questions: :not_a_list
           }}
      })

      result =
        QualityGate.evaluate([issue("ID-FEW-QUESTIONS"), issue("ID-BAD-QUESTIONS")], config, %{}, provider_module: StubProvider)

      assert [
               %{issue_id: "ID-FEW-QUESTIONS", questions: few_questions},
               %{issue_id: "ID-BAD-QUESTIONS", questions: fallback_questions}
             ] = result.awaiting_clarification

      assert few_questions == [
               "Which file should change?",
               "What specific acceptance criteria should the agent satisfy before opening a PR?",
               "Which files, modules, or product areas should the agent focus on?"
             ]

      assert fallback_questions == [
               "What specific acceptance criteria should the agent satisfy before opening a PR?",
               "Which files, modules, or product areas should the agent focus on?",
               "What scope boundaries or out-of-scope cases should the agent avoid?"
             ]
    end

    test "comment signatures ignore quality gate comments and tolerate malformed comments" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4)

      issue =
        issue("ID-MALFORMED-COMMENTS",
          comments: [
            %{body: " Operator answer without timestamp. "},
            %{not_body: true},
            %{body: "Symphony quality gate: skipped (score 3 < threshold 6).", created_at: ~U[2026-05-05 05:00:00Z]}
          ]
        )

      Process.put(:quality_gate_stub_results, %{
        "ID-MALFORMED-COMMENTS" => {:ok, %{score: 5, reason: "answer needs detail", questions: []}}
      })

      result = QualityGate.evaluate([issue], config, %{}, provider_module: StubProvider)

      assert [%{issue_id: "ID-MALFORMED-COMMENTS"}] = result.awaiting_clarification
      assert %{comment_signature: "1:" <> _hash} = Map.fetch!(result.cache, "ID-MALFORMED-COMMENTS")
    end

    test "comment signatures ignore agent workpad comments so workpad edits do not invalidate cache" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4)
      updated_at = ~U[2026-05-05 03:00:00Z]

      cache = %{
        "ID-WORKPAD" => %{
          updated_at: updated_at,
          comment_signature: nil,
          score: 5,
          reason: "needs clarification",
          passed?: false,
          awaiting_clarification?: true,
          questions: ["Existing question?"],
          rounds_asked: 1,
          max_rounds: 2,
          pass_threshold: 6,
          comment_posted?: true,
          identifier: "ACME-ID-WORKPAD",
          title: "Title ID-WORKPAD",
          state: "Todo",
          url: "https://linear.app/x/ID-WORKPAD",
          scored_at: updated_at
        }
      }

      cached_issue =
        issue("ID-WORKPAD",
          updated_at: updated_at,
          comments: [
            %{
              author: "Codex",
              body: "## Codex Workpad\nUpdated plan after agent run",
              created_at: ~U[2026-05-05 04:00:00Z]
            },
            %{
              author: "Claude",
              body: "## Claude Workpad\nClaude variant",
              created_at: ~U[2026-05-05 04:05:00Z]
            }
          ]
        )

      Process.put(:quality_gate_stub_results, %{
        "ID-WORKPAD" => {:ok, %{score: 9, reason: "should not run"}}
      })

      result = QualityGate.evaluate([cached_issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert [%{issue_id: "ID-WORKPAD", reason: "needs clarification"}] = result.awaiting_clarification
      assert Map.fetch!(result.cache, "ID-WORKPAD") == Map.fetch!(cache, "ID-WORKPAD")
    end

    test "comment activity falls back to nil for non-list issue comments" do
      config = config_enabled(min_score: 6)
      issue = issue("ID-NON-LIST-COMMENTS", comments: :not_a_list)

      Process.put(:quality_gate_stub_results, %{
        "ID-NON-LIST-COMMENTS" => {:ok, %{score: 8, reason: "clear"}}
      })

      result = QualityGate.evaluate([issue], config, %{}, provider_module: StubProvider)

      assert [%Issue{id: "ID-NON-LIST-COMMENTS"}] = result.passed
      assert %{comment_signature: nil} = Map.fetch!(result.cache, "ID-NON-LIST-COMMENTS")
    end

    test "uses cache when issue updated_at has not changed" do
      config = config_enabled(min_score: 6)
      updated_at = ~U[2026-05-05 03:00:00Z]
      cached_issue = issue("ID-1", updated_at: updated_at)

      cache = %{
        "ID-1" => %{
          updated_at: updated_at,
          score: 9,
          reason: "cached",
          passed?: true,
          comment_posted?: false,
          identifier: "ACME-1",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ACME-1",
          scored_at: ~U[2026-05-05 02:00:00Z]
        }
      }

      Process.put(:quality_gate_stub_results, %{
        "ID-1" => {:ok, %{score: 1, reason: "should not be called"}}
      })

      result = QualityGate.evaluate([cached_issue], config, cache, provider_module: StubProvider)

      assert [%Issue{id: "ID-1"}] = result.passed
      assert Map.get(result.cache, "ID-1").reason == "cached"
    end

    test "re-evaluates when updated_at changes (cache invalidated)" do
      config = config_enabled(min_score: 6)
      stale_at = ~U[2026-05-05 03:00:00Z]
      fresh_at = ~U[2026-05-05 04:00:00Z]
      fresh_issue = issue("ID-1", updated_at: fresh_at)

      cache = %{
        "ID-1" => %{
          updated_at: stale_at,
          score: 9,
          reason: "stale",
          passed?: true,
          comment_posted?: true,
          identifier: "ACME-1",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ACME-1",
          scored_at: stale_at
        }
      }

      Process.put(:quality_gate_stub_results, %{"ID-1" => {:ok, %{score: 4, reason: "rescored"}}})

      result = QualityGate.evaluate([fresh_issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert [%{kind: :scored, score: 4, reason: "rescored", comment_posted?: false}] = result.skipped
      assert %{updated_at: ^fresh_at, comment_posted?: false} = Map.get(result.cache, "ID-1")
    end

    test "reuses prior skip decision and preserves comment_posted? when cached" do
      config = config_enabled(min_score: 6)
      updated_at = ~U[2026-05-05 03:00:00Z]
      cached_issue = issue("ID-1", updated_at: updated_at)

      cache = %{
        "ID-1" => %{
          updated_at: updated_at,
          score: 3,
          reason: "vague",
          passed?: false,
          comment_posted?: true,
          identifier: "ACME-1",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ACME-1",
          scored_at: updated_at
        }
      }

      result = QualityGate.evaluate([cached_issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert [%{kind: :scored, comment_posted?: true, score: 3}] = result.skipped
    end

    test "on_error: pass lets the issue through when the LLM call fails" do
      config = config_enabled(min_score: 6, on_error: "pass")
      issues = [issue("ID-FAIL")]

      result = QualityGate.evaluate(issues, config, %{}, provider_module: ErroringProvider)

      assert [%Issue{id: "ID-FAIL"}] = result.passed
      assert result.skipped == []
      # Cache is not updated on failure
      assert result.cache == %{}
    end

    test "on_error: pass clears stale blocking cache entries" do
      config = config_enabled(min_score: 6, on_error: "pass")
      fresh_at = ~U[2026-05-05 04:00:00Z]
      stale_at = ~U[2026-05-05 03:00:00Z]
      issues = [issue("ID-FAIL", updated_at: fresh_at)]

      cache = %{
        "ID-FAIL" => %{
          updated_at: stale_at,
          score: 5,
          reason: "needs clarification",
          passed?: false,
          awaiting_clarification?: true,
          comment_posted?: true,
          identifier: "ACME-ID-FAIL",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/ID-FAIL",
          scored_at: stale_at
        }
      }

      result = QualityGate.evaluate(issues, config, cache, provider_module: ErroringProvider)

      assert [%Issue{id: "ID-FAIL"}] = result.passed
      assert result.skipped == []
      assert result.awaiting_clarification == []
      assert result.cache == %{}
    end

    test "on_error: skip removes the issue and produces an error skip entry" do
      config = config_enabled(min_score: 6, on_error: "skip")
      issues = [issue("ID-FAIL")]

      result = QualityGate.evaluate(issues, config, %{}, provider_module: ErroringProvider)

      assert result.passed == []
      assert [%{kind: :error, issue_id: "ID-FAIL", error: :stub_boom, reason: reason}] = result.skipped
      assert reason =~ "LLM call failed"
      # Cache is not updated on failure (so we retry next cycle)
      assert result.cache == %{}
    end

    test "missing API key behaves like an LLM failure under on_error" do
      System.delete_env("ANTHROPIC_API_KEY")
      config = config_enabled(min_score: 6, on_error: "skip")

      result = QualityGate.evaluate([issue("ID-1")], config, %{}, provider_module: StubProvider)

      assert [%{kind: :error, error: :missing_anthropic_api_key}] = result.skipped
      assert result.cache == %{}
    end
  end

  describe "mark_comment_posted/3" do
    test "flips comment_posted? to true and stamps posted_at for the matching cache entry" do
      cache = %{
        "ID-1" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          score: 3,
          reason: "vague",
          passed?: false,
          comment_posted?: false,
          posted_at: nil,
          identifier: nil,
          title: nil,
          state: nil,
          url: nil,
          scored_at: ~U[2026-05-05 03:00:00Z]
        }
      }

      posted_at = ~U[2026-05-05 03:30:00Z]
      updated = QualityGate.mark_comment_posted(cache, %{issue_id: "ID-1"}, posted_at)
      assert Map.get(updated, "ID-1").comment_posted?
      assert Map.get(updated, "ID-1").posted_at == posted_at
    end

    test "is a no-op when the cache has no entry for the skip" do
      assert QualityGate.mark_comment_posted(%{}, %{issue_id: "ID-MISSING"}, DateTime.utc_now()) == %{}
    end

    test "is a no-op when the entry has no issue id" do
      cache = %{
        "ID-1" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          score: 3,
          reason: "vague",
          passed?: false,
          comment_posted?: false,
          posted_at: nil,
          identifier: nil,
          title: nil,
          state: nil,
          url: nil,
          scored_at: ~U[2026-05-05 03:00:00Z]
        }
      }

      assert QualityGate.mark_comment_posted(cache, %{}, DateTime.utc_now()) == cache
    end
  end

  describe "skip_comment_body/2" do
    test "describes the score and threshold for score-based skips" do
      config = config_enabled(min_score: 6)
      entry = %{kind: :scored, score: 3, reason: "vague description"}

      body = QualityGate.skip_comment_body(entry, config)

      assert body =~ "score 3"
      assert body =~ "threshold 6"
      assert body =~ "vague description"
      assert body =~ "edit the description"
    end

    test "names the clarification cap when max rounds are exhausted" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4, max_clarification_rounds: 2)
      entry = %{kind: :scored, score: 5, reason: "still vague", max_rounds_reached?: true, rounds_asked: 2}

      body = QualityGate.skip_comment_body(entry, config)

      assert body =~ "Asked 2 times; still below pass_threshold"
      assert body =~ "Skipping until description is updated"
      assert body =~ "still vague"
    end

    test "explains LLM failures for error-based skips" do
      config = config_enabled(min_score: 6)
      entry = %{kind: :error, reason: "LLM call failed: :stub_boom"}

      body = QualityGate.skip_comment_body(entry, config)

      assert body =~ "LLM call failed"
      assert body =~ "threshold 6"
    end
  end

  describe "clarification_comment_body/2" do
    test "renders a deterministic numbered question list" do
      config = config_enabled(pass_threshold: 6, clarification_floor: 4)

      entry = %{
        kind: :clarification,
        score: 5,
        reason: "missing targets",
        questions: ["Which file should change?", "What should pass?", "What is out of scope?"],
        rounds_asked: 1,
        max_rounds: 2
      }

      body = QualityGate.clarification_comment_body(entry, config)

      assert body =~ "Symphony quality gate: clarification requested"
      assert body =~ "score 5 < pass_threshold 6"
      assert body =~ "round 1/2"
      assert body =~ "1. Which file should change?"
      assert body =~ "3. What is out of scope?"
      assert body =~ "1-2 sentences per question"
    end
  end

  describe "skipped_from_cache/1" do
    test "returns only skipped entries, sorted by most-recently scored" do
      cache = %{
        "ID-PASS" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          score: 9,
          reason: "ok",
          passed?: true,
          comment_posted?: false,
          identifier: "ACME-PASS",
          title: "Pass",
          state: "Todo",
          url: nil,
          scored_at: ~U[2026-05-05 03:00:00Z]
        },
        "ID-OLD" => %{
          updated_at: ~U[2026-05-05 02:00:00Z],
          score: 3,
          reason: "vague",
          passed?: false,
          comment_posted?: true,
          identifier: "ACME-OLD",
          title: "Old",
          state: "Todo",
          url: nil,
          scored_at: ~U[2026-05-05 01:00:00Z]
        },
        "ID-NEW" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          score: 4,
          reason: "broad",
          passed?: false,
          comment_posted?: false,
          identifier: "ACME-NEW",
          title: "New",
          state: "Todo",
          url: nil,
          scored_at: ~U[2026-05-05 03:30:00Z]
        }
      }

      assert [
               %{kind: :scored, issue_id: "ID-NEW", score: 4},
               %{kind: :scored, issue_id: "ID-OLD", score: 3}
             ] = QualityGate.skipped_from_cache(cache)
    end
  end

  describe "awaiting_clarification_from_cache/1" do
    test "returns only awaiting clarification entries sorted by most-recently scored" do
      cache = %{
        "ID-PASS" => %{
          passed?: true,
          awaiting_clarification?: false,
          scored_at: ~U[2026-05-05 03:00:00Z]
        },
        "ID-SKIP" => %{
          passed?: false,
          awaiting_clarification?: false,
          scored_at: ~U[2026-05-05 03:00:00Z]
        },
        "ID-AWAIT" => %{
          passed?: false,
          awaiting_clarification?: true,
          identifier: "ACME-AWAIT",
          title: "Await",
          state: "Todo",
          url: nil,
          score: 5,
          reason: "needs answer",
          rounds_asked: 2,
          scored_at: ~U[2026-05-05 04:00:00Z]
        }
      }

      assert [
               %{kind: :clarification, issue_id: "ID-AWAIT", identifier: "ACME-AWAIT", rounds_asked: 2}
             ] = QualityGate.awaiting_clarification_from_cache(cache)
    end
  end

  describe "retain_active_issues/2" do
    test "drops cache entries whose issue ids no longer appear" do
      cache = %{
        "ID-KEEP" => %{passed?: false},
        "ID-DROP" => %{passed?: true}
      }

      kept = QualityGate.retain_active_issues(cache, [issue("ID-KEEP")])

      assert Map.has_key?(kept, "ID-KEEP")
      refute Map.has_key?(kept, "ID-DROP")
    end

    test "ignores non-issue entries in the active list" do
      cache = %{"ID-KEEP" => %{passed?: false}}

      assert QualityGate.retain_active_issues(cache, [%{not_an_issue: true}]) == %{}
    end
  end

  describe "provider_settings/1" do
    test "resolves the OpenAI api key from the environment" do
      config = config_enabled(provider: "openai", model: "gpt-5")

      assert {:ok, %{provider: "openai", model: "gpt-5", api_key: api_key}} =
               QualityGate.provider_settings(config)

      assert Secret.unwrap(api_key) == "test-openai-key"
      assert inspect(api_key) == "#Secret<[FILTERED]>"
    end

    test "errors when the OpenAI api key is missing" do
      System.delete_env("OPENAI_API_KEY")
      config = config_enabled(provider: "openai", model: "gpt-5")

      assert {:error, :missing_openai_api_key} = QualityGate.provider_settings(config)
    end

    test "errors for unsupported provider strings" do
      config = %SymphonyElixir.Config.Schema.QualityGate{
        enabled: true,
        provider: "huggingface",
        model: "any",
        min_score: 6,
        on_error: "pass"
      }

      assert {:error, {:unsupported_provider, "huggingface"}} =
               QualityGate.provider_settings(config)
    end

    test "resolves provider/model from schema defaults" do
      assert {:ok,
              %{
                api_key: api_key,
                provider: "anthropic",
                model: "claude-haiku-4-5-20251001"
              }} = QualityGate.provider_settings(%SymphonyElixir.Config.Schema.QualityGate{})

      assert Secret.unwrap(api_key) == "test-anthropic-key"
    end

    test "errors when provider/model are nil" do
      assert {:error, :missing_provider_settings} =
               QualityGate.provider_settings(%SymphonyElixir.Config.Schema.QualityGate{
                 provider: nil,
                 model: nil
               })
    end
  end

  describe "evaluate/4 falls back to defaults" do
    test "passes malformed issues through with a warning" do
      config = config_enabled(min_score: 6)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = QualityGate.evaluate([%{not_a_struct: true}], config, %{}, provider_module: StubProvider)
          send(self(), {:result, result})
        end)

      assert_received {:result, %{passed: [_], skipped: []}}
      assert log =~ "QualityGate received malformed issue"
    end

    test "uses the default provider module when none is overridden" do
      config = config_enabled(min_score: 6, provider: "openai", model: "gpt-5")

      Application.put_env(:symphony_elixir, :quality_gate_openai_module, StubProvider)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :quality_gate_openai_module) end)

      Process.put(:quality_gate_stub_results, %{"ID-OPENAI" => {:ok, %{score: 8, reason: "ok"}}})

      result = QualityGate.evaluate([issue("ID-OPENAI")], config, %{})

      assert [%Issue{id: "ID-OPENAI"}] = result.passed
    end
  end

  defp config_enabled(opts) do
    %QualityGateConfig{
      enabled: true,
      provider: Keyword.get(opts, :provider, "anthropic"),
      model: Keyword.get(opts, :model, "claude-haiku-4-5-20251001"),
      min_score: Keyword.get(opts, :min_score, 6),
      pass_threshold: Keyword.get(opts, :pass_threshold),
      clarification_floor: Keyword.get(opts, :clarification_floor),
      max_clarification_rounds: Keyword.get(opts, :max_clarification_rounds, 2),
      on_error: Keyword.get(opts, :on_error, "pass")
    }
  end

  defp issue(id, opts \\ []) do
    %Issue{
      id: id,
      identifier: Keyword.get(opts, :identifier, "ACME-#{id}"),
      title: Keyword.get(opts, :title, "Title #{id}"),
      description: Keyword.get(opts, :description, "Some description"),
      state: Keyword.get(opts, :state, "Todo"),
      url: Keyword.get(opts, :url, "https://linear.app/x/#{id}"),
      labels: Keyword.get(opts, :labels, []),
      comments: Keyword.get(opts, :comments, []),
      updated_at: Keyword.get(opts, :updated_at, ~U[2026-05-05 03:00:00Z])
    }
  end
end
