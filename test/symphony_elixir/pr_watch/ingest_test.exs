defmodule SymphonyElixir.PrWatch.IngestTest do
  @moduledoc """
  GitHub's webhook deliveries feeding the PR and CI watcher (TP-948): the fact patch table, the
  confirm read, a push re-reading the PRs on its base, the delivery health and the safety-net
  pace it sets.
  """

  use SymphonyElixir.TestSupport

  import SymphonyElixir.PrWatchParity,
    only: [check_failed: 2, check_passed: 2, synchronize: 2, merged: 1, push: 0, push: 1, red: 0]

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.{Health, Ingest, Release, Repo}
  alias SymphonyElixir.PrWatchParity, as: Parity

  @repo_key "default"
  @repo_url "https://github.com/acme/app"

  defmodule FailingTracker do
    def fetch_issues_by_states_with_failures(_states), do: {:error, :linear_down}
  end

  setup do
    start_supervised!(Parity)
    workflow!(true)
    :ok
  end

  defp workflow!(enabled, webhooks \\ %{}) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 20},
      github: %{webhooks: Map.merge(%{enabled: enabled, secret: "s3cret"}, webhooks)}
    )
  end

  defp watch(attrs \\ []) do
    Map.merge(
      %{
        pr_url: "#{@repo_url}/pull/1",
        head_sha: "head-1",
        base_ref: "main",
        facts: Facts.new(%{phase: :code_review, pr: :open, ci: :pending, mergeable: :clean})
      },
      Map.new(attrs)
    )
  end

  defp started!(tickets, opts \\ []) do
    Parity.tickets!(%{tickets: tickets})
    pid = Parity.start!(opts)
    Parity.tick!(pid)
    pid
  end

  defp health, do: Health.load(RunStore, @repo_key)
  defp next_tick_ms(pid), do: elem(Repo.poll(pid), 1).next_tick_ms

  describe "the fact patch table" do
    test "a failed check on the record's head reads red; a pass, a cancel or another head patches nothing" do
      assert %{facts: %{ci: :red}} = Ingest.patch(check_failed("1", "head-1"), watch())

      {:ci, failed} = check_failed("1", "head-1")

      for delivery <- [check_passed("1", "head-1"), check_failed("1", "head-0"), {:ci, %{failed | conclusion: "cancelled"}}] do
        assert Ingest.patch(delivery, watch()) == watch()
      end

      assert Ingest.patch({:ci, %{elem(check_failed("1", "head-1"), 1) | conclusion: nil}}, watch()) == watch()
    end

    test "a moved head reads pending with mergeability unknown; a closed, merged or reopened PR says so" do
      assert %{head_sha: "head-2", facts: %{ci: :pending, mergeable: :unknown}} = Ingest.patch(synchronize("1", "head-2"), watch(facts: %{watch().facts | ci: :green}))
      assert Ingest.patch(synchronize("1", "head-1"), watch()) == watch()

      assert %{facts: %{pr: :merged}} = Ingest.patch(merged("1"), watch())
      {:ci, closed} = merged("1")
      assert %{facts: %{pr: :closed}} = Ingest.patch({:ci, %{closed | merged: false}}, watch())
      assert %{facts: %{pr: :open}, head_sha: "head-3"} = Ingest.patch({:ci, %{closed | action: "reopened", head_sha: "head-3"}}, watch(facts: %{watch().facts | pr: :closed}))
      assert %{head_sha: "head-1"} = Ingest.patch({:ci, %{closed | action: "reopened"}}, watch())
    end

    test "a push makes mergeability unknown; a ping, a release or an ignored delivery patches nothing" do
      assert %{facts: %{mergeable: :unknown}} = Ingest.patch(push(), watch())

      for delivery <- [:ping, :ignored, {:release, %{repo: "tonypine/symphony", tag: "v1", published_at: nil, prerelease: false}}] do
        assert Ingest.patch(delivery, watch()) == watch()
        refute Ingest.names?(delivery, watch())
      end
    end

    test "a delivery names a record by its PR, a check by its head, and a push by the open PRs on its base" do
      assert Ingest.names?(synchronize("1", "head-9"), watch(pr_url: "https://GitHub.com/acme/app/pull/1/"))
      refute Ingest.names?(synchronize("2", "head-1"), watch())
      assert Ingest.names?({:ci, %{elem(check_failed("9", "head-1"), 1) | pr_urls: []}}, watch())
      refute Ingest.names?({:ci, %{elem(synchronize("9", "head-1"), 1) | pr_urls: []}}, watch())
      refute Ingest.names?({:ci, %{elem(check_failed("9", nil), 1) | pr_urls: []}}, watch(head_sha: nil))

      assert Ingest.names?(push(), watch())
      assert Ingest.names?(push(), watch(base_ref: nil))
      refute Ingest.names?(push("release"), watch())
      refute Ingest.names?({:push, %{repo_url: "https://github.com/acme/other", ref: "main", head_sha: nil}}, watch())
      refute Ingest.names?(push(), watch(facts: %{watch().facts | pr: :merged}))
      refute Ingest.names?(synchronize("1", "head-9"), watch(pr_url: nil))
    end

    test "a push, or a PR that closed by merging, moved its base" do
      assert Ingest.base_moved(push(), nil) == elem(push(), 1)
      assert Ingest.base_moved(merged("1"), nil) == %{repo_url: @repo_url, ref: "main", head_sha: nil}
      assert %{repo_url: "https://github.com/acme/fork"} = Ingest.base_moved(merged("1"), "https://github.com/acme/fork")
      assert Ingest.base_moved(synchronize("1", "head-2"), nil) == nil
    end

    test "repository_of/1 and within?/2 read a PR's repository" do
      assert Ingest.repository_of("#{@repo_url}/pull/12") == @repo_url
      assert Ingest.repository_of("https://github.com/acme") == nil
      assert Ingest.repository_of(nil) == nil
      assert Ingest.within?("#{@repo_url}/pull/1", "https://github.com/ACME/app/")
      assert Ingest.within?(@repo_url, @repo_url)
      refute Ingest.within?("https://github.com/acme/application/pull/1", @repo_url)
      refute Ingest.within?(nil, @repo_url)
    end
  end

  describe "deliver/3 and reject/3" do
    test "with no watcher running, a delivery is unavailable and a release is still recorded" do
      assert Ingest.deliver(:ping, nil, watchers: []) == :unavailable
      assert Ingest.deliver(:ping, nil) == :unavailable
      assert Ingest.reject(:bad_signature, @repo_url, watchers: []) == :unavailable

      release = %{repo: "tonypine/symphony", tag: "v2.0.0", published_at: ~U[2026-10-16 08:00:00Z], prerelease: false}
      assert Ingest.deliver({:release, release}, "https://github.com/tonypine/symphony", watchers: [:nobody]) == :ok
      assert %{tag: "v2.0.0", published_at: ~U[2026-10-16 08:00:00Z], source: :webhook} = Release.latest()
    end

    test "deliveries reach every registered watcher" do
      Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
      pid = Parity.start!(name: Repo.name(@repo_key))
      Parity.tick!(pid)

      assert Ingest.deliver(check_failed("1", "head-1-1"), @repo_url) == :ok
      assert Ingest.reject(:bad_signature, @repo_url) == :ok
      _state = :sys.get_state(pid)

      assert_received {:pr_watch_timer, :confirm, 3_000}
      assert %{deliveries: 1, signature_failures: [_one]} = health()
    end
  end

  describe "a delivery and its confirm read" do
    test "patches the named record at once, marked as a delivery's, and the confirm read decides on GitHub's read" do
      pid = started!([{"1", "Code Review", []}, {"2", "QA", []}])
      Parity.change!([{"1", red()}])

      :ok = Ingest.deliver(check_failed("1", "head-1-1"), @repo_url, watchers: [pid])
      :ok = Ingest.deliver(check_failed("1", "head-1-1"), @repo_url, watchers: [pid])
      _state = :sys.get_state(pid)

      # One confirm read for the burst; until then the record carries the patch.
      assert_received {:pr_watch_timer, :confirm, 3_000}
      refute_received {:pr_watch_timer, :confirm, _delay}
      assert %{source: :webhook, facts: %{ci: :red}, delivered_at: delivered_at, decision: %{rule: "R27"}} = Parity.watch("1")
      assert delivered_at == Parity.now()
      assert %{source: :poll} = Parity.watch("2")

      Parity.advance!(3_000)
      send(pid, :confirm)
      _state = :sys.get_state(pid)
      assert %{source: :webhook, decision: %{rule: "R22"}, read_at: read_at} = Parity.watch("1")
      assert read_at == Parity.now()
      assert %{source: :poll} = Parity.watch("2")
      assert %{deliveries: 2, results_via_webhook: 1} = health()
    end

    test "a confirm read whose Linear read fails leaves the timed tick's backoff alone" do
      Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
      pid = Parity.start!(tracker: FailingTracker)
      capture_log(fn -> assert {:error, :linear_down} = Repo.poll(pid) end)
      assert :sys.get_state(pid).failures == 1

      :ok = Ingest.deliver(check_failed("1", "head-1-1"), @repo_url, watchers: [pid])
      _state = :sys.get_state(pid)
      log = capture_log(fn -> send(pid, :confirm) && :sys.get_state(pid) end)

      assert log =~ "PR watch tick failed repo_key=default reason=:linear_down"
      assert :sys.get_state(pid).failures == 1
    end

    test "a merged PR moves its base: the other open PRs on it are re-read 1 s apart, the merged one confirmed" do
      pid = started!([{"1", "Merging", []}, {"2", "QA", []}, {"3", "Code Review", []}, {"4", "QA", base_ref: "release"}])
      flush_timers()

      :ok = Ingest.deliver(merged("1"), nil, watchers: [pid])
      _state = :sys.get_state(pid)

      assert_received {:pr_watch_timer, :confirm, 3_000}
      assert_received {:pr_watch_timer, :reread, 1_000}
      assert %{facts: %{pr: :merged}} = Parity.watch("1")
      assert %{facts: %{mergeable: :unknown}, source: :webhook} = Parity.watch("2")
      assert %{facts: %{mergeable: :unknown}} = Parity.watch("3")
      assert %{facts: %{mergeable: :clean}, source: :poll} = Parity.watch("4")
      assert :sys.get_state(pid).rereads == ["issue-2", "issue-3"]

      # A second push before the rereads ran queues nobody twice.
      :ok = Ingest.deliver(push(), @repo_url, watchers: [pid])
      assert :sys.get_state(pid).rereads == ["issue-2", "issue-3"]

      send(pid, :reread)
      _state = :sys.get_state(pid)
      assert %{facts: %{mergeable: :clean}, read_at: read_at} = Parity.watch("2")
      assert read_at == Parity.now()
      assert_received {:pr_watch_timer, :reread, 1_000}
      send(pid, :reread)
      assert :sys.get_state(pid).rereads == []
      refute_received {:pr_watch_timer, :reread, _delay}

      # A reread timer with nothing queued does nothing.
      send(pid, :reread)
      assert %{reread_timer: nil} = :sys.get_state(pid)
    end

    test "a PR whose mergeability GitHub hasn't computed yet is read again after the others, up to 5 times" do
      pid = started!([{"1", "Code Review", []}, {"2", "QA", []}])
      flush_timers()
      Parity.change!([{"1", mergeable: :unknown}, {"2", mergeable: :unknown}])

      :ok = Ingest.deliver(push(), @repo_url, watchers: [pid])
      _state = :sys.get_state(pid)

      # 1, 2, then 1 again; 2 settles to DIRTY on its second read and goes to CI Fix.
      reread!(pid, 2)
      Parity.change!([{"2", mergeable: :dirty}])
      assert %{rereads: ["issue-1", "issue-2"]} = :sys.get_state(pid)
      reread!(pid, 2)
      assert %{rereads: ["issue-1"], reread_tries: %{"issue-1" => 2}} = :sys.get_state(pid)
      assert Parity.state("2") == "CI Fix"

      # Still unknown after its fifth read, it is left to the timed tick.
      reread!(pid, 3)
      assert %{rereads: [], reread_tries: tries} = :sys.get_state(pid)
      assert tries == %{}
      assert %{facts: %{mergeable: :unknown}} = Parity.watch("1")
    end

    test "a confirm read that finds a conflict or a competitor wait reads every watched PR and the open PRs, as a poll does" do
      Parity.tickets!(%{
        tickets: [{"1", "QA", []}, {"2", "Merging", ci: :pending, mergeable: :blocked, auto_merge: :armed}],
        files: %{"1" => ["SPEC.md"], "2" => ["SPEC.md", "lib/b.ex"]}
      })

      pid = Parity.start!()
      Parity.tick!(pid)
      flush_timers()
      Parity.change!([{"2", mergeable: :dirty}])
      Parity.advance!(1_000)

      # PR 2's reread finds the conflict: PR 1 is read again with it, and the conflict waits on PR 1.
      :ok = Ingest.deliver(push(), @repo_url, watchers: [pid])
      reread!(pid, 2)
      assert %{decision: %{rule: "R14a", kind: :wait_for_competitors}, source: :webhook} = Parity.watch("2")
      assert %{read_at: read_at} = Parity.watch("1")
      assert read_at == Parity.now()
      assert Parity.state("2") == "Merging"
      assert Parity.blockers("2") == ["TP-1"]

      # PR 1 merges: PR 2's reread sees it gone from the open PRs, its hold clears and it gets its CI Fix run.
      Parity.change!([{"1", pr: :merged}])
      :ok = Ingest.deliver(merged("1"), nil, watchers: [pid])
      reread!(pid, 1)
      assert Parity.state("2") == "CI Fix"
      assert %{decision: %{rule: "R14"}} = Parity.watch("2")
      assert Parity.ending("2").holds == []
    end

    test "a ping reads every watched PR now" do
      pid = started!([{"1", "Code Review", []}])
      Parity.change!([{"1", red()}])
      Parity.advance!(1_000)

      :ok = Ingest.deliver(:ping, nil, watchers: [pid])
      _state = :sys.get_state(pid)

      assert %{decision: %{rule: "R22"}, read_at: read_at, source: :poll} = Parity.watch("1")
      assert read_at == Parity.now()
      assert %{deliveries: 1} = health()
    end

    test "a delivery about another repository is not this one's, and patches nothing" do
      pid = started!([{"1", "Code Review", []}])
      other = "https://github.com/acme/other"

      {:ci, failed} = check_failed("1", "head-1-1")
      :ok = Ingest.deliver({:ci, %{failed | pr_urls: ["#{other}/pull/1"], head_sha: "zzz"}}, other, watchers: [pid])
      :ok = Ingest.deliver({:push, %{repo_url: other, ref: "main", head_sha: nil}}, other, watchers: [pid])
      :ok = Ingest.deliver(:ping, other, watchers: [pid])
      :ok = Ingest.reject(:bad_signature, other, watchers: [pid])
      :ok = Ingest.reject(:bad_signature, nil, watchers: [pid])
      _state = :sys.get_state(pid)

      refute_received {:pr_watch_timer, _message, _delay}
      assert %{source: :poll} = Parity.watch("1")
      assert %{deliveries: 0, signature_failures: [], github_url: @repo_url} = health()

      # One naming the repository counts, whatever it is about.
      :ok = Ingest.deliver(:ignored, @repo_url, watchers: [pid])
      :ok = Ingest.reject(:bad_signature, "#{@repo_url}/", watchers: [pid])
      _state = :sys.get_state(pid)
      assert %{deliveries: 1, signature_failures: [_one]} = health()
    end

    test "a watcher with no record yet knows the repository by the PRs it watches" do
      Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
      pid = Parity.start!()
      :ok = RunStore.put_ticket_pr_watch(@repo_key, "issue-9", "TP-9", Map.merge(watch(pr_url: "#{@repo_url}/pull/9"), %{source: :poll, read_at: nil, github: :ok}))

      :ok = Ingest.reject(:bad_signature, @repo_url, watchers: [pid])
      _state = :sys.get_state(pid)
      assert %{signature_failures: [_one], github_url: nil} = health()
    end
  end

  describe "health and the safety-net pace" do
    test "healthy deliveries slow the timed tick to the safety net; a read that finds an unreported change brings 30 s back at once" do
      pid = started!([{"1", "Code Review", []}])
      assert next_tick_ms(pid) == 30_000

      :ok = Ingest.deliver(:ignored, @repo_url, watchers: [pid])
      assert next_tick_ms(pid) == 300_000
      assert Health.healthy?(health(), Config.settings!().github.webhooks)

      # The relay stopped; the PR changed. The next reconcile read finds it.
      Parity.change!([{"1", head_sha: "head-1-2", ci: :pending}])
      Parity.advance!(300_000)

      log = capture_log(fn -> assert next_tick_ms(pid) == 30_000 end)
      assert log =~ "PR watch found a change no GitHub delivery reported repo_key=default issue_identifier=TP-1 pr_url=#{@repo_url}/pull/1 change=head"
      assert %{missed: 1, last_missed: %{change: :head, pr_url: "#{@repo_url}/pull/1"}} = health()
      refute Health.healthy?(health(), Config.settings!().github.webhooks)

      # The relay is back: its next delivery makes the deliveries healthy again.
      Parity.advance!(1_000)
      :ok = Ingest.deliver(synchronize("1", "head-1-3"), @repo_url, watchers: [pid])
      Parity.change!([{"1", head_sha: "head-1-3"}])
      assert next_tick_ms(pid) == 300_000
      assert %{missed: 1} = health()
    end

    test "a change a delivery reported, or one found on a confirm read, is no missed delivery" do
      pid = started!([{"1", "Code Review", []}])
      :ok = Ingest.deliver(synchronize("1", "head-1-2"), @repo_url, watchers: [pid])
      Parity.change!([{"1", head_sha: "head-1-2", ci: :pending}])
      Parity.advance!(1_000)
      assert next_tick_ms(pid) == 300_000

      Parity.change!([{"1", ci: :green}])
      send(pid, :confirm)
      _state = :sys.get_state(pid)
      assert %{missed: 0, results_via_webhook: 1} = health()
    end

    test "with webhooks off the watcher keeps the poll interval and counts no missed delivery" do
      workflow!(false)
      pid = started!([{"1", "Code Review", []}])
      :ok = Ingest.deliver(:ignored, @repo_url, watchers: [pid])
      Parity.change!([{"1", red()}])

      assert next_tick_ms(pid) == 30_000
      assert %{missed: 0, results_via_poll: 1} = health()
    end

    test "a relay that keeps stopping keeps the poll interval, read again each tick" do
      relay = start_supervised!({Agent, fn -> %{state: :running, stable: false} end}, id: :relay)
      pid = started!([{"1", "Code Review", []}], relay_status: fn "default" -> Agent.get(relay, & &1) end)
      :ok = Ingest.deliver(:ignored, @repo_url, watchers: [pid])
      assert next_tick_ms(pid) == 30_000
      assert Health.healthy?(health(), Config.settings!().github.webhooks)

      Agent.update(relay, &%{&1 | stable: true})
      assert next_tick_ms(pid) == 300_000
    end

    test "the safety-net interval is the setting's" do
      workflow!(true, %{fallback_poll_interval_ms: 120_000})
      pid = started!([{"1", "Code Review", []}])
      :ok = Ingest.deliver(:ignored, @repo_url, watchers: [pid])
      assert next_tick_ms(pid) == 120_000
    end

    test "without a test timer, a delivery arms a real one for the confirm read" do
      Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
      fakes = [tracker: Parity.Tracker, fetch: Parity.Fetch, github: Parity.GitHub]
      pid = start_supervised!({Repo, [repo_key: @repo_key, name: nil, auto: false] ++ fakes})
      Parity.tick!(pid)

      :ok = Ingest.deliver(check_failed("1", "head-1-1"), @repo_url, watchers: [pid])
      assert %{confirm_timer: timer} = :sys.get_state(pid)
      assert is_integer(Process.read_timer(timer))
    end

    test "the health survives a restart" do
      pid = started!([{"1", "Code Review", []}])
      :ok = Ingest.deliver(:ignored, @repo_url, watchers: [pid])
      _state = :sys.get_state(pid)
      stop_supervised!({Repo, @repo_key})

      pid = Parity.start!()
      assert %{health: %{deliveries: 1, github_url: @repo_url}} = :sys.get_state(pid)
      assert next_tick_ms(pid) == 300_000
    end
  end

  describe "status/1" do
    test "sums the repositories' health for the dashboard, with the app's newest release" do
      now = ~U[2026-10-16 12:00:00Z]
      health = Health.new() |> Health.delivered(~U[2026-10-16 11:58:00Z]) |> Health.rejected(now) |> Health.result(:webhook) |> Health.result(:poll)
      :ok = Health.save(RunStore, @repo_key, health)
      :ok = Health.save(RunStore, "other", Health.delivered(Health.new(), ~U[2026-10-16 11:00:00Z]))
      Release.record_published(%{repo: "tonypine/symphony", tag: "v3", published_at: now, prerelease: false}, [])

      status = Ingest.status(repo_keys: [@repo_key, "other", "quiet"], now: fn -> now end)

      assert %{enabled: true, relay: "smee", last_event_at: ~U[2026-10-16 11:58:00Z], events_received: 2, rejected: 1} = status
      assert %{results_via_webhook: 1, results_via_poll: 1, app_release: %{tag: "v3"}} = status
      assert %{healthy: true, silent: false} = status.repos[@repo_key]
      assert %{healthy: true, silent: true} = status.repos["other"]
      assert %{healthy: false, silent: true, last_delivery_at: nil} = status.repos["quiet"]

      assert %{repos: repos, last_event_at: nil} = Ingest.status(repo_keys: [], now: fn -> now end)
      assert repos == %{}
      assert %{enabled: true} = Ingest.status()
    end
  end

  defp reread!(pid, times) do
    for _read <- 1..times do
      send(pid, :reread)
      _state = :sys.get_state(pid)
    end
  end

  defp flush_timers do
    receive do
      {:pr_watch_timer, _message, _delay} -> flush_timers()
    after
      0 -> :ok
    end
  end
end
