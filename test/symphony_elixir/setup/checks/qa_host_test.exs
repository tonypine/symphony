defmodule SymphonyElixir.Setup.Checks.QaHostTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.QaHost

  @docs_fix %{kind: "open", target: "symphony_yml", url: "https://github.com/tonypine/symphony/blob/main/docs/configuration.md#running-qa-in-a-qa-vm"}
  @macos_app %{macos_app: %{build: "make -C macos qa-app", app: "macos/build/Symphony.app"}}
  @this_mac "1A2B3C4D-0000-1111-2222-333344445555"

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :setup_qa_machine) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok
  end

  defp write_qa_config!(auto_review), do: write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", auto_review: auto_review)

  defp problems, do: Setup.check(checks: [QaHost], linear_api_key?: true).problems

  defp ioreg(uuid), do: {:ok, {~s(+-o Mac  <class IOPlatformExpertDevice>\n    {\n      "IOPlatformUUID" = "#{uuid}"\n    }\n), 0}}

  # Fakes `ioreg` on this host (`@this_mac`) and on the QA host, which answers `qa_reply`.
  defp fake_machines(qa_reply) do
    test = self()

    qa_cmd = fn worker_host, executable, args, _opts ->
      send(test, {:qa_cmd, worker_host, executable, args})
      qa_reply
    end

    Application.put_env(:symphony_elixir, :setup_qa_machine, qa_cmd: qa_cmd, local_uuid: fn -> {:ok, @this_mac} end)
  end

  test "names itself, reads no Linear, and has nothing to report without macos_app" do
    assert QaHost.id() == "qa_host"
    assert is_binary(QaHost.title())
    refute QaHost.needs_linear?()
    assert QaHost.run(%{system: nil}) == []
    fake_machines(ioreg(@this_mac))
    write_qa_config!(%{worker_host: "qa@localhost"})

    assert problems() == []
    refute_received {:qa_cmd, _host, _executable, _args}
  end

  test "macos_app with no worker_host is an error that opens the QA VM docs" do
    write_qa_config!(%{playbooks: @macos_app})

    assert [problem] = problems()
    assert problem.id == "qa_host:missing"
    assert problem.severity == "error"
    assert problem.category == "runtime"
    assert problem.title == "macOS app QA has no QA VM"
    assert problem.consequence =~ "QA of default builds and launches no macOS app: it runs only in a QA VM"
    assert problem.repos == ["default"]
    assert problem.fix == @docs_fix
    assert %{label: "Key", value: "auto_review.worker_host"} in problem.details
  end

  test "a worker_host that is this Mac under another name is an error; a VM is not" do
    fake_machines(ioreg(String.downcase(@this_mac)))
    write_qa_config!(%{playbooks: @macos_app, worker_host: "qa@tonys-mac.local"})

    assert [problem] = problems()
    assert problem.id == "qa_host:same_machine:qa@tonys-mac.local"
    assert problem.severity == "error"
    assert problem.title == "The QA host qa@tonys-mac.local is this Mac"
    assert problem.consequence =~ "QA runs only in a VM, never on the Symphony Mac"
    assert problem.repos == ["default"]
    assert problem.fix == @docs_fix
    assert %{label: "Value", value: "qa@tonys-mac.local"} in problem.details
    assert_received {:qa_cmd, "qa@tonys-mac.local", "/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]}

    fake_machines(ioreg("99999999-8888-7777-6666-555544443333"))
    assert problems() == []
  end

  test "a QA host it can't read leaves the check not checked" do
    fake_machines({:error, :timeout})
    write_qa_config!(%{playbooks: @macos_app, worker_host: "qa@qa-vm"})

    assert %{problems: [], not_checked: [not_checked]} = Setup.check(checks: [QaHost], linear_api_key?: true)
    assert not_checked.id == "qa_host"
    assert not_checked.reason =~ "the QA host qa@qa-vm: the hardware UUID of the QA host could not be read: ioreg could not run: :timeout"
  end
end
