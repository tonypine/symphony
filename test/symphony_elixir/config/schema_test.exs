defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "the QA review refuses a playbook PlaybookSettings refuses, naming it" do
    changeset = Schema.AutoReview.changeset(%Schema.AutoReview{}, %{"playbooks" => %{"cli" => %{"live" => %{"start_cmd" => "x"}}}})

    refute changeset.valid?
    assert {message, _} = changeset.errors[:playbooks]
    assert message =~ "live is only read on the macos_app playbook"
  end

  test "the Conductor lists every junction in the order a ticket meets them" do
    assert Schema.Conductor.junctions() == ~w(after_coding after_qa_fail after_qa_blocked after_rework before_merge)
  end
end
