# Wrote `pre_epic_1/` beside this file: a store as Symphony's own writers left it at f01bfff4, the
# last commit before epic 1 (TP-1087), with nothing written by hand. To write it again, from a
# checkout of that commit:
#
#   OLD_STORE_DIR=<dir> MIX_ENV=dev mix run --no-start -e 'Code.eval_file("<this file>")'
#
# and copy the files of <dir> (not its empty `core_dumps`) into `pre_epic_1/`.
alias SymphonyElixir.RunStore
dir = System.fetch_env!("OLD_STORE_DIR")
File.rm_rf!(dir)
{:ok, _} = RunStore.start_link(dir: dir)
repo = "symphony"

for {id, ident, phase} <- [{"issue-1", "ACME-1", "Done"}, {"issue-2", "ACME-2", "QA"}, {"issue-3", "ACME-3", "In Progress"}, {"issue-4", "ACME-4", "Rework"}] do
  :ok = RunStore.put_ticket_state(%{repo_key: repo, issue_id: id, issue_identifier: ident, phase: phase})
  :ok = RunStore.record_ticket_signal(repo, id, "handoff", %{head: "abc" <> id})
  :ok = RunStore.record_ticket_verdict(repo, id, "code_review", "abc" <> id, "approve", %{reasons: ["fine"]})
  :ok = RunStore.record_ticket_dispatch(repo, id, %{kind: "implementation", state: phase, run_id: "run-" <> id, head: "abc" <> id})
end

# A ticket that moved to another Linear project: one record under each repository.
:ok = RunStore.put_ticket_state(%{repo_key: repo, issue_id: "issue-5", issue_identifier: "ACME-5", phase: "In Progress", observed_at: ~U[2026-10-01 10:00:00Z]})
:ok = RunStore.record_ticket_signal(repo, "issue-5", "handoff", %{head: "old"})
:ok = RunStore.put_ticket_state(%{repo_key: "other-repo", issue_id: "issue-5", issue_identifier: "ACME-5", phase: "QA", observed_at: ~U[2026-10-02 10:00:00Z]})
:ok = RunStore.record_ticket_signal("other-repo", "issue-5", "handoff", %{head: "new"})
:ok = RunStore.record_ticket_verdict("other-repo", "issue-5", "code_review", "new", "approve", %{})
IO.inspect(length(RunStore.list_all_ticket_states()), label: "tickets written")
GenServer.stop(RunStore)
:mnesia.stop()
