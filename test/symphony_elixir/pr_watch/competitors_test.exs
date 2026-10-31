defmodule SymphonyElixir.PrWatch.CompetitorsTest do
  @moduledoc """
  The paths of `SymphonyElixir.PrWatch.Competitors` the watcher's tick tests don't reach: a wait
  whose competitors only partly leave, Linear or the store refusing a write, and a person's release.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, TicketState}
  alias SymphonyElixir.Pauses.Dependencies
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Competitors

  @repo_key "default"
  @issue %Issue{id: "issue-2", identifier: "TP-2", state: "Merging", blocked_by: []}
  @now ~U[2026-10-16 12:00:00Z]
  @ticket {:ticket, "default", "issue-2"}

  defmodule Linker do
    def add_blocked_by(blocker, issue_id), do: send(self(), {:link, blocker, issue_id}) && Process.get(:link_result, :ok)
    def remove_blocked_by(blocker, issue_id), do: send(self(), {:unlink, blocker, issue_id}) && Process.get(:unlink_result, :ok)
  end

  defmodule DownStore do
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :store_down}
  end

  defp link(number, attrs \\ []) do
    Map.merge(
      %{
        issue_id: "issue-#{number}",
        issue_identifier: "TP-#{number}",
        pr_number: number,
        pr_url: "https://github.com/acme/app/pull/#{number}",
        title: "Ticket #{number}",
        files: ["SPEC.md"],
        head_sha: "head-#{number}",
        progress_at: @now,
        linked: true,
        step_behind: false,
        released: false
      },
      Map.new(attrs)
    )
  end

  defp pull(number, files \\ ["SPEC.md"]), do: %{number: number, url: "https://github.com/acme/app/pull/#{number}", title: "Ticket #{number}", head_sha: "head-#{number}", files: files}

  defp race(pulls, attrs \\ []) do
    Map.merge(%{pulls: Map.new(pulls, &{&1.number, &1}), members: %{}, blockers: %{}, merged: MapSet.new(), files: ["SPEC.md"], now: @now}, Map.new(attrs))
  end

  defp opts(attrs \\ []), do: Keyword.merge([repo_key: @repo_key, terminal_states: ["Done"], linker: Linker], attrs)

  # The ticket waits on `links`: its pause has their landing reasons.
  defp wait!(links) do
    for reason <- Competitors.landing_reasons(links), do: {:ok, _pause} = Pauses.set(@ticket, reason)
    Competitors.waiting(TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue.id)))
  end

  describe "settle/5" do
    test "a competitor that left is unlinked and the wait names the ones left" do
      wait = wait!([link(1), link(3)])
      assert wait.reason == "Waiting for TP-1 to land: it changes the same files; Waiting for TP-3 to land: it changes the same files"
      settled = Competitors.settle(@issue, wait, [link(1), link(3)], race([pull(3)]), opts())

      assert_received {:unlink, "TP-1", "issue-2"}
      assert [%{issue_identifier: "TP-3"}] = settled.links
      assert settled.wait == %{reason: "Waiting on TP-3 to land: they change the same files (SPEC.md)", set_at: wait.set_at}
      assert Pauses.why(@ticket) == ["Waiting for TP-3 to land: it changes the same files"]
    end

    test "a blocker whose ticket is terminal landed: its link stays" do
      issue = %{@issue | blocked_by: [%{id: "issue-1", identifier: "TP-1", state: nil}, %{id: "issue-1", identifier: "TP-1", state: "Done"}]}
      wait = wait!([link(1)])

      assert %{wait: nil, links: [], restart_conflicts: false} = Competitors.settle(issue, wait, [link(1)], race([]), opts())
      refute_received {:unlink, _blocker, _issue_id}
    end

    test "a link Linear refuses to remove keeps its competitor waited on, for the next read to try again" do
      Process.put(:unlink_result, {:error, :linear_down})
      wait = wait!([link(1)])

      log = capture_log(fn -> assert %{wait: %{}, links: [%{issue_identifier: "TP-1"}]} = Competitors.settle(@issue, wait, [link(1)], race([]), opts()) end)
      assert log =~ "could not unlink TP-1"
      assert Pauses.paused?(@ticket)
    end

    test "a wait whose reasons the store won't clear stays as it was" do
      wait = wait!([link(1), link(3)])

      links = [link(1, linked: false), link(3, step_behind: true)]
      log = capture_log(fn -> assert %{wait: ^wait, links: ^links} = Competitors.settle(@issue, wait, links, race([]), opts(repo_key: nil)) end)

      assert log =~ "could not end the landing wait"
    end

    test "without a wait every competitor not landed is unlinked" do
      released = link(12, issue_id: nil, issue_identifier: nil, linked: false, released: true)

      assert %{wait: nil, links: [^released], restart_conflicts: false} =
               Competitors.settle(@issue, nil, [released, link(1)], race([pull(1), pull(12)]), opts())

      assert_received {:unlink, "TP-1", "issue-2"}
    end
  end

  describe "the landing reasons and the wait's line" do
    @tracked %{issue_identifier: "TP-1", pr_number: 1, pr_url: "https://github.com/acme/app/pull/1", files: ["SPEC.md", "a.ex"]}
    @person %{pr_number: 12, pr_url: "https://github.com/acme/app/pull/12", title: "Docs pass", files: ["SPEC.md", "b.md"]}
    @untitled %{pr_number: 13, files: ["SPEC.md"]}

    test "the line names each competitor, its ticket else its PR, and the files they share" do
      assert Competitors.landing_text([@tracked, @person, @untitled]) ==
               "Waiting on TP-1 and PR #12 (Docs pass) and PR #13 to land: they change the same files (SPEC.md, a.ex, b.md)"
    end

    test "one reason per competitor, which the Director may release" do
      competitors = [@tracked, @person, @untitled, @tracked, %{files: ["SPEC.md"]}, %{issue_identifier: "not-a-ticket", files: []}]

      assert Competitors.landing_reasons(competitors) == [
               %{kind: :ticket, waits_on: %{identifier: "TP-1"}, text: "Waiting for TP-1 to land: it changes the same files", releasable: true},
               %{
                 kind: :environment,
                 waits_on: %{condition: "pull_request:12"},
                 text: "Waiting for PR #12 (Docs pass) to land: it changes the same files",
                 releasable: true
               },
               %{kind: :environment, waits_on: %{condition: "pull_request:13"}, text: "Waiting for PR #13 to land: it changes the same files", releasable: true}
             ]

      assert [%{text: text}] = Competitors.landing_reasons([%{@person | title: String.duplicate("x", 400)}])
      assert String.length(text) < 300
    end

    test "tells a landing reason from any other, whoever wrote it" do
      for reason <- Competitors.landing_reasons([@tracked, @person]), do: assert(Competitors.landing_reason?(reason))

      refute Competitors.landing_reason?(Pauses.ticket_reason(:dependency, "TP-1"))
      refute Competitors.landing_reason?(%{kind: :environment, waits_on: %{condition: "pull_request:12 and more"}})
      refute Competitors.landing_reason?(%{kind: :question, waits_on: %{question_id: "q1"}})
      refute Competitors.landing_reason?(nil)
    end

    test "the wait reads the competitors the watch record names, else the reasons' own lines, and none without a reason" do
      assert Competitors.waiting(nil) == nil
      assert Competitors.waiting(TicketState.normalize(%{repo_key: @repo_key, issue_id: @issue.id})) == nil

      {:ok, _links} = Competitors.wait(@issue, [link(1), link(3)], false, opts(now: @now))
      :ok = RunStore.put_ticket_pr_watch(@repo_key, @issue.id, "TP-2", %{facts: SymphonyElixir.PrDecision.Facts.new(), links: [link(1), link(3, released: true)]})
      record = TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue.id))

      assert %{reason: "Waiting on TP-1 to land: they change the same files (SPEC.md)", set_at: %DateTime{}} = Competitors.waiting(record)
    end
  end

  describe "competing/3 and excluded?/3" do
    test "a forced ticket has none; a released PR without a ticket is matched by number" do
      own = %{issue_id: "issue-2", pr_number: 2, files: ["SPEC.md"], forced: false, links: [link(12, issue_id: nil, released: true)]}

      assert Competitors.competing(%{own | forced: true}, [pull(1)], race([])) == []
      assert [%{pr_number: 1}] = Competitors.competing(own, [pull(1), pull(2), pull(12), pull(14, ["README.md"])], race([]))
      assert %Facts{competing: [%{pr_number: 1}]} = Facts.new(competing: Competitors.competing(own, [pull(1)], race([])))
    end

    test "a cycle is found through others, and a loop in the links ends the search" do
      blockers = %{"a" => ["b"], "b" => ["c", "a"], "c" => ["own"]}

      assert Competitors.closes_cycle?(blockers, "a", "own")
      refute Competitors.closes_cycle?(blockers, "a", "other")
      refute Competitors.closes_cycle?(blockers, nil, "own")
    end
  end

  describe "release/3" do
    test "removes Symphony's links and marks every competitor released" do
      :ok = RunStore.put_ticket_pr_watch(@repo_key, @issue.id, "TP-2", %{facts: Facts.new(), links: [link(1), link(3, linked: false)]})
      Process.put(:unlink_result, {:error, :linear_down})

      capture_log(fn -> assert :ok = Competitors.release(@repo_key, @issue.id, linker: Linker) end)
      assert_received {:unlink, "TP-1", "issue-2"}
      refute_received {:unlink, "TP-3", _issue_id}

      assert [%{released: true, linked: false}, %{released: true}] = @repo_key |> RunStore.get_ticket_state(@issue.id) |> TicketState.pr_watch() |> Map.fetch!(:links)
    end

    test "a ticket with nothing recorded has nothing to release; a store that can't be read is the error" do
      assert :ok = Competitors.release(@repo_key, "issue-none")
      assert {:error, :store_down} = Competitors.release(@repo_key, @issue.id, store: DownStore)
    end
  end

  describe "the pause beside the wait" do
    test "a wait pauses the ticket once, one reason per competitor" do
      person = %{pr_number: 12, pr_url: "https://github.com/acme/app/pull/12", title: "Bump deps", files: ["SPEC.md"], head_sha: "head-12"}
      competitors = [Map.take(link(1), [:issue_id, :issue_identifier, :pr_number, :pr_url, :title, :files, :head_sha]), person]

      assert {:ok, _links} = Competitors.wait(@issue, competitors, false, opts(now: @now))
      assert {:ok, _links} = Competitors.wait(@issue, competitors, false, opts(now: @now))

      assert Pauses.why(@ticket) == [
               "Waiting for TP-1 to land: it changes the same files",
               "Waiting for PR #12 (Bump deps) to land: it changes the same files"
             ]

      assert {:ok, %{reasons: [%{kind: :ticket, releasable: true, set_by: setter}, %{kind: :environment, releasable: true}]}} = Pauses.get(@ticket)
      assert setter == Dependencies.setter(:landing)

      # A pause the store refuses is the wait's error.
      assert {:error, {:invalid_subject, _subject}} = Competitors.wait(@issue, competitors, false, opts(now: @now, repo_key: nil))
    end

    test "a competitor that lands loses its reason; the last one clears the pause" do
      {:ok, _links} = Competitors.wait(@issue, [link(1), link(3)], false, opts(now: @now))
      wait = Competitors.waiting(TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue.id)))
      issue = %{@issue | blocked_by: [%{id: "issue-1", identifier: "TP-1", state: "Done"}]}

      settled = Competitors.settle(issue, wait, [link(1), link(3)], race([pull(3)]), opts())
      assert Pauses.why(@ticket) == ["Waiting for TP-3 to land: it changes the same files"]

      issue = %{issue | blocked_by: issue.blocked_by ++ [%{id: "issue-3", identifier: "TP-3", state: "Done"}]}
      assert %{wait: nil} = Competitors.settle(issue, settled.wait, settled.links, race([]), opts())
      assert {:ok, nil} = Pauses.get(@ticket)
    end

    test "a wait still standing has a reason its pause lost set again, and nothing more" do
      {:ok, _links} = Competitors.wait(@issue, [link(1)], false, opts(now: @now))
      wait = Competitors.waiting(TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue.id)))
      {:ok, nil} = Pauses.clear(@ticket)

      assert %{wait: %{}} = Competitors.settle(@issue, wait, [link(1)], race([pull(1)]), opts())
      assert Pauses.why(@ticket) == ["Waiting for TP-1 to land: it changes the same files"]
    end

    test "with no wait left, the landing reasons go and every other reason stays" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-9"))
      {:ok, _pause} = Pauses.set(@ticket, Map.put(Pauses.ticket_reason(:landing, "TP-1"), :releasable, true))

      Competitors.settle(@issue, nil, [link(1)], race([pull(1)]), opts())
      assert Pauses.why(@ticket) == ["Waiting for TP-9 to finish"]
    end

    test "Unblock's release clears every landing reason, the backfill's too, by the Director, and nothing else" do
      {:ok, _links} = Competitors.wait(@issue, [link(1), link(12, issue_id: nil, issue_identifier: nil, title: nil)], false, opts(now: @now))
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:landing, "TP-5"), backfilled: true)
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-9"))

      assert "Waiting for PR #12 to land: it changes the same files" in Pauses.why(@ticket)

      capture_log(fn -> assert :ok = Competitors.release(@repo_key, @issue.id, linker: Linker) end)
      assert Pauses.why(@ticket) == ["Waiting for TP-9 to finish"]

      assert %{payload: %{by: %{kind: :person, name: "Director"}}} =
               @repo_key |> RunStore.list_ticket_events(@issue.id, types: ["pause.reason_cleared"]) |> List.last()
    end

    test "a ticket the watcher leaves loses its landing reasons" do
      {:ok, _links} = Competitors.wait(@issue, [link(1)], false, opts(now: @now))
      record = TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue.id))

      capture_log(fn -> assert :ok = Competitors.leave(@repo_key, record, opts()) end)
      assert {:ok, nil} = Pauses.get(@ticket)
    end
  end
end
