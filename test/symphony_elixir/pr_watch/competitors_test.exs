defmodule SymphonyElixir.PrWatch.CompetitorsTest do
  @moduledoc """
  The paths of `SymphonyElixir.PrWatch.Competitors` the watcher's tick tests don't reach: a wait
  whose competitors only partly leave, Linear or the store refusing a write, and a person's release.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BlockedHold, Hold, TicketState}
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Competitors

  @repo_key "default"
  @issue %Issue{id: "issue-2", identifier: "TP-2", state: "Merging", blocked_by: []}
  @now ~U[2026-10-16 12:00:00Z]

  defmodule Linker do
    def add_blocked_by(blocker, issue_id), do: send(self(), {:link, blocker, issue_id}) && Process.get(:link_result, :ok)
    def remove_blocked_by(blocker, issue_id), do: send(self(), {:unlink, blocker, issue_id}) && Process.get(:unlink_result, :ok)
  end

  defmodule Tracker do
    def set_machine_label(_issue_id, _label), do: :ok
    def clear_machine_label(_issue_id, _label), do: :ok
  end

  # Reads through the real store; refuses every hold write.
  defmodule RefusingStore do
    def get_ticket_state(repo_key, issue_id), do: SymphonyElixir.RunStore.get_ticket_state(repo_key, issue_id)
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :store_down}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :store_down}
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

  defp opts(attrs \\ []), do: Keyword.merge([repo_key: @repo_key, terminal_states: ["Done"], tracker: Tracker, linker: Linker], attrs)

  defp hold!(links) do
    :ok = Hold.set(@repo_key, @issue.id, :blocked, BlockedHold.landing_attrs(links), tracker: Tracker)
    Hold.get(@repo_key, @issue.id, :blocked)
  end

  describe "settle/5" do
    test "a competitor that left is unlinked and the hold names the ones left" do
      hold = hold!([link(1), link(3)])
      settled = Competitors.settle(@issue, hold, [link(1), link(3)], race([pull(3)]), opts())

      assert_received {:unlink, "TP-1", "issue-2"}
      assert [%{issue_identifier: "TP-3"}] = settled.links
      assert settled.hold.reason == "Waiting on TP-3 to land: they change the same files (SPEC.md)"
      assert Hold.get(@repo_key, @issue.id, :blocked).reason == settled.hold.reason
    end

    test "a blocker whose ticket is terminal landed: its link stays" do
      issue = %{@issue | blocked_by: [%{id: "issue-1", identifier: "TP-1", state: nil}, %{id: "issue-1", identifier: "TP-1", state: "Done"}]}
      hold = hold!([link(1)])

      assert %{hold: nil, links: [], restart_conflicts: false} = Competitors.settle(issue, hold, [link(1)], race([]), opts())
      refute_received {:unlink, _blocker, _issue_id}
    end

    test "a link Linear refuses to remove keeps its competitor waited on, for the next read to try again" do
      Process.put(:unlink_result, {:error, :linear_down})
      hold = hold!([link(1)])

      log = capture_log(fn -> assert %{hold: %{}, links: [%{issue_identifier: "TP-1"}]} = Competitors.settle(@issue, hold, [link(1)], race([]), opts()) end)
      assert log =~ "could not unlink TP-1"
      assert Hold.held?(@repo_key, @issue.id, :blocked)
    end

    test "a hold the store won't clear or rename stays as it was" do
      hold = hold!([link(1), link(3)])

      links = [link(1, linked: false), link(3, step_behind: true)]
      log = capture_log(fn -> assert %{hold: ^hold, links: ^links} = Competitors.settle(@issue, hold, links, race([]), opts(store: RefusingStore)) end)

      assert log =~ "could not clear the landing hold"
      assert %{hold: ^hold, links: [%{pr_number: 3}]} = Competitors.settle(@issue, hold, [link(1, linked: false), link(3)], race([pull(3)]), opts(store: RefusingStore))
    end

    test "without a landing hold the wait is over: every competitor not landed is unlinked" do
      released = link(12, issue_id: nil, issue_identifier: nil, linked: false, released: true)

      assert %{hold: nil, links: [^released], restart_conflicts: false} =
               Competitors.settle(@issue, %{waits_on: %{type: "access", keys: []}}, [released, link(1)], race([pull(1), pull(12)]), opts())

      assert_received {:unlink, "TP-1", "issue-2"}
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
end
