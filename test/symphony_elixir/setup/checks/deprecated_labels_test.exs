defmodule SymphonyElixir.Setup.Checks.DeprecatedLabelsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Routing.PollLog
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.DeprecatedLabels

  setup do
    on_exit(fn -> :ets.delete(PollLog, "app") end)
    :ok
  end

  defp route!(repo \\ %{}, overrides \\ []) do
    path = Workflow.workflow_file_path()
    repos = [Map.merge(%{key: "app", team: "TP", workflow: path}, repo)]
    write_workflow_file!(path, Keyword.merge([tracker_kind: "memory", repos: repos], overrides))
  end

  defp check, do: Setup.check(checks: [DeprecatedLabels])

  test "names itself and reads no Linear" do
    assert DeprecatedLabels.id() == "deprecated_label"
    assert DeprecatedLabels.title() == "Deprecated labels in symphony.yml and on tickets"
    refute DeprecatedLabels.needs_linear?()
  end

  test "a config and tickets without human-action are clean" do
    route!()
    [repo] = Config.system!().repos
    PollLog.record(repo, {:ok, [%Issue{id: "i1", identifier: "TP-1", labels: ["plan", nil]}]})

    assert %{problems: [], not_checked: []} = check()
  end

  test "human-action in the global escalate.labels shows with a Remove fix" do
    capture_log(fn -> route!(%{}, auto_review: %{"acceptance_gate" => %{"escalate" => %{"labels" => ["needs-human", "human-action"]}}}) end)

    assert %{problems: [problem]} = check()
    assert problem.id == "deprecated_label:config:auto_review.acceptance_gate.escalate.labels"
    assert problem.severity == "warning"
    assert problem.category == "labels"
    assert problem.title == ~s(symphony.yml lists the deprecated "human-action" label in auto_review.acceptance_gate.escalate.labels)
    assert problem.consequence =~ ~s(Symphony asks you for decisions with the "Needs Decision" label now)
    assert %{label: "Key", value: "auto_review.acceptance_gate.escalate.labels"} in problem.details
    assert problem.fix == %{kind: "config_edit", path: "auto_review.acceptance_gate.escalate.labels", action: "remove", value: "human-action"}
  end

  test "human-action in a repository's escalate.labels names that list" do
    capture_log(fn -> route!(%{acceptance_gate: %{"escalate" => %{"labels" => ["Human-Action"]}}}) end)

    assert %{problems: [problem]} = check()
    assert problem.id == "deprecated_label:config:repositories[app].acceptance_gate.escalate.labels"
    assert problem.fix.value == "Human-Action"
    refute Enum.any?(problem.details, &(&1.label == "Line"))
  end

  test "open tickets carrying human-action are listed by identifier" do
    route!()
    [repo] = Config.system!().repos

    PollLog.record(
      repo,
      {:ok,
       [
         %Issue{id: "i1", identifier: "TP-1", url: "https://linear.app/t/issue/TP-1", labels: ["human-action"]},
         %Issue{id: "i2", identifier: "TP-2", labels: ["plan"]}
       ]}
    )

    assert %{problems: [problem]} = check()
    assert problem.id == "deprecated_label:tickets:app"
    assert problem.title == ~s(1 open ticket in app carries the deprecated "human-action" label)
    assert problem.repos == ["app"]
    assert problem.tickets == [%{identifier: "TP-1", url: "https://linear.app/t/issue/TP-1"}]
    assert problem.fix == %{kind: "open", target: "linear", url: nil}

    PollLog.record(repo, {:ok, [%Issue{id: "i1", identifier: "TP-1", labels: ["human-action"]}, %Issue{id: "i3", identifier: "TP-3", labels: ["Human-Action"]}]})
    assert %{problems: [%{title: ~s(2 open tickets in app carry the deprecated "human-action" label)}]} = check()
  end

  test "a symphony.yml that doesn't load and no running config are no problem here" do
    File.write!(Workflow.symphony_file_path(), "issues: [")
    Cache.clear()

    assert DeprecatedLabels.run(%{system: nil, symphony_path: Workflow.symphony_file_path()}) == []
  end
end
