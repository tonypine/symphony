defmodule SymphonyElixir.PrWatch.ReleaseTest do
  @moduledoc """
  The app repository's newest release as a repo fact (TP-948, after TP-1050): written by a
  `release` delivery and by the safety-net tick's one conditional read, to the same result.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrWatch.{Ingest, Release}
  alias SymphonyElixir.PrWatchParity, as: Parity
  alias SymphonyElixirWeb.WatchPayload

  @published ~U[2026-10-16 08:00:00Z]
  @release %{repo: "tonypine/symphony", tag: "v1.4.0", published_at: @published, prerelease: false}

  defmodule FailingStore do
    def get_github_updates(_key), do: nil
    def put_github_updates(_key, _value), do: {:error, :store_down}
  end

  setup do
    start_supervised!(Parity)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", pr_review_mode: "polling", ci: %{enabled: true})
    :ok
  end

  # `gh api --include` as GitHub answers `releases/latest`: each call gets the next answer, and the
  # arguments are sent to the test.
  defp gh(answers) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> answers end)

    fn args, _opts ->
      send(test, {:gh, args})
      Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
    end
  end

  defp ok(tag, published_at, etag) do
    body = Jason.encode!(%{"tag_name" => tag, "published_at" => published_at, "prerelease" => false})
    {"HTTP/2.0 200 OK\r\nEtag: #{etag}\r\nX-Ratelimit-Remaining: 4999\r\n\r\n#{body}", 0}
  end

  defp not_modified, do: {"HTTP/2.0 304 Not Modified\r\nEtag: \"e1\"\r\n\r\n", 0}

  test "a published delivery and the poll-only path record the same newest release" do
    :ok = Ingest.deliver({:release, @release}, "https://github.com/tonypine/symphony", watchers: [])
    delivered = Release.latest()

    clear_run_store!()
    Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
    pid = Parity.start!(app_release: true, gh_runner: gh([ok("v1.4.0", "2026-10-16T08:00:00Z", ~s("e1")), not_modified()]))
    Parity.tick!(pid)
    polled = Release.latest()

    assert Map.take(delivered, [:repo, :tag, :published_at]) == %{repo: "tonypine/symphony", tag: "v1.4.0", published_at: @published}
    assert Map.take(polled, [:repo, :tag, :published_at]) == Map.take(delivered, [:repo, :tag, :published_at])
    assert %{source: :poll, etag: ~s("e1"), recorded_at: recorded_at} = polled
    assert recorded_at == Parity.now()
    assert_received {:gh, ["api", "--include", "repos/tonypine/symphony/releases/latest"]}

    # The next tick asks conditionally: at most one request, and an unchanged release costs nothing.
    Parity.tick!(pid)
    assert_received {:gh, ["api", "--include", "-H", ~s(If-None-Match: "e1"), "repos/tonypine/symphony/releases/latest"]}
    refute_received {:gh, _args}
    assert Release.latest() == polled
  end

  # What `GET /api/v1/state` tells the app under `app_update`, without how the release arrived.
  defp reported_to_app do
    [] |> WatchPayload.app_update(Release.latest()) |> Map.fetch!(:latest_release) |> Map.delete(:source)
  end

  test "with webhooks off, one safety-net tick reports the release to the app as a delivery does" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      github: %{webhooks: %{enabled: false}}
    )

    :ok = Ingest.deliver({:release, @release}, "https://github.com/tonypine/symphony", watchers: [])
    delivered = reported_to_app()

    clear_run_store!()
    assert WatchPayload.app_update([], Release.latest()).latest_release == nil
    Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
    pid = Parity.start!(app_release: true, gh_runner: gh([ok("v1.4.0", "2026-10-16T08:00:00Z", ~s("e1"))]))
    Parity.tick!(pid)

    assert delivered == %{repo: "tonypine/symphony", tag: "v1.4.0", published_at: "2026-10-16T08:00:00Z"}
    assert reported_to_app() == delivered
  end

  test "a watcher without app_release never reads the release" do
    Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
    pid = Parity.start!(gh_runner: gh([]))
    Parity.tick!(pid)

    refute_received {:gh, _args}
    assert Release.latest() == nil
  end

  test "a read that fails is only logged at debug level, and the fact stays" do
    Release.record_published(@release, [])
    Parity.tickets!(%{tickets: [{"1", "Code Review", []}]})
    pid = Parity.start!(app_release: true, gh_runner: gh([{"gh: Bad credentials (HTTP 401)", 1}]))

    Parity.tick!(pid)
    assert %{tag: "v1.4.0", source: :webhook} = Release.latest()
  end

  describe "record_published/2" do
    test "records the app repository's release when it is newer, and leaves anything else alone" do
      assert Release.record_published(@release, now: fn -> @published end) == :recorded
      assert %{tag: "v1.4.0", etag: nil, source: :webhook, recorded_at: @published} = Release.latest()

      older = %{@release | tag: "v1.3.0", published_at: ~U[2026-10-01 08:00:00Z]}
      assert Release.record_published(older, []) == :ignored
      assert Release.record_published(@release, []) == :ignored
      assert Release.record_published(%{@release | repo: "acme/app", tag: "v9"}, []) == :ignored
      assert Release.record_published(%{@release | repo: nil, tag: "v9"}, []) == :ignored
      assert Release.record_published(%{@release | prerelease: true, tag: "v9"}, []) == :ignored
      assert Release.record_published(:nothing, []) == :ignored

      newer = %{@release | repo: "TonyPine/Symphony", tag: "v1.5.0", published_at: DateTime.add(@published, 60)}
      assert Release.record_published(newer, []) == :recorded
      assert %{tag: "v1.5.0"} = Release.latest()

      # Without a publish time, a new tag is newer.
      assert Release.record_published(%{@release | tag: "v1.6.0", published_at: nil}, []) == :recorded
      assert Release.record_published(%{@release | tag: "v1.6.0", published_at: nil}, []) == :ignored
    end

    test "a store that can't be written is logged" do
      log =
        capture_log(fn ->
          assert {:error, :store_down} = Release.record_published(@release, run_store: FailingStore)
        end)

      assert log =~ "Could not record the newest release of tonypine/symphony tag=v1.4.0 reason=:store_down"
    end
  end

  describe "poll/1" do
    test "reads 304 as unchanged, whether gh exits 0 or not" do
      assert Release.poll(gh_runner: gh([not_modified()])) == :not_modified
      assert Release.poll(gh_runner: gh([{"HTTP/2.0 304 Not Modified\r\n\r\ngh: HTTP 304", 1}])) == :not_modified
    end

    test "an error, another status or a body without a tag is an error" do
      assert {:error, {:gh_failed, _args, 1, "HTTP/2.0 404 Not Found\r\n\r\n{}"}} = Release.poll(gh_runner: gh([{"HTTP/2.0 404 Not Found\r\n\r\n{}", 1}]))
      assert Release.poll(gh_runner: gh([{"HTTP/2.0 500 Oops", 0}])) == {:error, {:unexpected_release_answer, 500}}
      assert Release.poll(gh_runner: gh([{"HTTP/2.0 200 OK\r\n\r\n{\"tag_name\": \"\"}", 0}])) == {:error, {:unexpected_release_answer, 200}}
      assert Release.poll(gh_runner: gh([{"not http", 0}])) == {:error, {:unexpected_release_answer, nil}}
      assert Release.poll(gh_runner: gh([{:error, :enoent}])) == {:error, :enoent}
      assert Release.latest() == nil
    end

    test "a release with an unreadable or no publish time is recorded without one" do
      assert Release.poll(gh_runner: gh([ok("v2.0.0", "soon", ~s("e2"))])) == :recorded
      assert %{tag: "v2.0.0", published_at: nil, etag: ~s("e2")} = Release.latest()
      assert Release.poll(gh_runner: gh([ok("v2.1.0", nil, ~s("e3"))])) == :recorded
      assert %{tag: "v2.1.0", published_at: nil} = Release.latest()
    end
  end
end
