defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "the QA review refuses a playbook PlaybookSettings refuses, naming it" do
    changeset = Schema.AutoReview.changeset(%Schema.AutoReview{}, %{"playbooks" => %{"cli" => %{"live" => %{"start_cmd" => "x"}}}})

    refute changeset.valid?
    assert {message, _} = changeset.errors[:playbooks]
    assert message =~ "auto_review.playbooks.cli.live is gone: the project's server is described once, in verification.dev_server"
  end

  test "the project's server takes a runs rule from a closed set, symphony_host by default" do
    assert Schema.Verification.DevServer.runs_values() == ~w(symphony_host every_qa_pass live_qa_pass)
    assert %Schema.Verification.DevServer{runs: "symphony_host"} = %Schema.Verification.DevServer{}

    for runs <- Schema.Verification.DevServer.runs_values() do
      assert Schema.Verification.DevServer.changeset(%Schema.Verification.DevServer{}, %{"runs" => runs}).valid?
    end

    changeset = Schema.Verification.DevServer.changeset(%Schema.Verification.DevServer{}, %{"runs" => "sometimes"})
    assert {"must be one of symphony_host, every_qa_pass, live_qa_pass", _} = changeset.errors[:runs]
  end

  test "the Conductor lists every junction in the order a ticket meets them" do
    assert Schema.Conductor.junctions() == ~w(grooming after_coding after_qa_fail after_qa_blocked after_rework before_merge message sub_ticket_ended final_check child_message)
  end
end
