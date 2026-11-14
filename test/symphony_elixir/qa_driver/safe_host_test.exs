defmodule SymphonyElixir.QaDriver.SafeHostTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.QaDriver.SafeHost

  @symphony_mac "1A2B3C4D-0000-1111-2222-333344445555"
  @qa_vm "99999999-8888-7777-6666-555544443333"

  setup do
    scratch = Path.join(System.tmp_dir!(), "safe-host-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf(scratch) end)
    %{opts: [scratch_dir: scratch, local_uuid: fn -> {:ok, @symphony_mac} end], scratch: scratch}
  end

  defp host(uuid, prepare) do
    test = self()

    %{
      cmd: fn "/usr/sbin/ioreg", _args, _opts -> uuid end,
      prepare: fn operator_home, canary ->
        send(test, {:prepare, operator_home, canary})
        prepare
      end
    }
  end

  defp ioreg(uuid), do: {:ok, {~s(    "IOPlatformUUID" = "#{uuid}"\n), 0}}

  test "a QA host that is another machine and passes the credentials check gets a run directory", %{opts: opts, scratch: scratch} do
    log = capture_log(fn -> assert SafeHost.open(host(ioreg(@qa_vm), {:ok, "/qa/run.1"}), "qa-vm", opts) == {:ok, "/qa/run.1"} end)

    assert log =~ "QA driver runs on worker_host=qa-vm dir=/qa/run.1"
    canary = Path.join(scratch, "canary")
    assert_received {:prepare, home, ^canary}
    assert home == System.user_home!()
    assert Bitwise.band(File.stat!(canary).mode, 0o777) == 0o600
  end

  test "no QA host is refused", %{opts: opts} do
    log =
      capture_log(fn ->
        assert {:error, {"qa_worker_missing", message}} = SafeHost.open(%{}, nil, [user: "QA build"] ++ opts)
        assert message =~ "`auto_review.worker_host` is unset"
      end)

    assert log =~ "QA build has no worker_host"
  end

  test "the Symphony host under another name is refused, and so is one that can't be told apart", %{opts: opts} do
    log =
      capture_log(fn ->
        assert {:error, {"qa_worker_same_machine", message}} = SafeHost.open(host(ioreg(@symphony_mac), :unused), "localhost", opts)
        assert message =~ "The QA host localhost is this Mac"

        assert {:error, {"qa_worker_unreachable", message}} = SafeHost.open(host({:error, :timeout}, :unused), "qa-vm", opts)
        assert message =~ "The QA host qa-vm could not be checked: the hardware UUID of the QA host could not be read"
      end)

    assert log =~ "QA driver refused worker_host=localhost: it is the Symphony host"
    assert log =~ "QA driver could not tell worker_host=qa-vm from the Symphony host"
    refute_received {:prepare, _home, _canary}
  end

  test "a QA host that reaches credentials, or can't be prepared, is refused", %{opts: opts} do
    log =
      capture_log(fn ->
        assert {:error, {"qa_worker_unsafe", message}} =
                 SafeHost.open(host(ioreg(@qa_vm), {:error, {:unsafe, "has a forwarded SSH agent"}}), "qa-vm", [user: "QA build"] ++ opts)

        assert message =~ "The QA host qa-vm has a forwarded SSH agent."

        assert {:error, {"qa_worker_unreachable", message}} =
                 SafeHost.open(host(ioreg(@qa_vm), {:error, {:unreachable, "ssh exited with status 255"}}), "qa-vm", opts)

        assert message =~ "The QA host qa-vm could not be prepared: ssh exited with status 255."
      end)

    assert log =~ "QA build refused worker_host=qa-vm: has a forwarded SSH agent"
    assert log =~ "QA driver could not reach worker_host=qa-vm: ssh exited with status 255"
  end
end
