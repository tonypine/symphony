defmodule SymphonyElixir.QaDriver.MachineTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaDriver.Machine

  @uuid "1A2B3C4D-0000-1111-2222-333344445555"

  defp ioreg(reply) do
    test = self()

    fn executable, args, opts ->
      send(test, {:cmd, executable, args, opts})
      reply
    end
  end

  defp output(uuid), do: {:ok, {~s(+-o Mac  <class IOPlatformExpertDevice>\n    {\n      "IOPlatformUUID" = "#{uuid}"\n    }\n), 0}}

  test "reads IOPlatformUUID from ioreg, upper-cased" do
    assert Machine.platform_uuid(ioreg(output(String.downcase(@uuid)))) == {:ok, @uuid}
    assert_received {:cmd, "/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"], opts}
    assert opts[:timeout_ms] == 30_000

    assert Machine.platform_uuid(ioreg({:ok, {"+-o Mac\n", 0}})) == {:error, "ioreg printed no IOPlatformUUID"}
    assert Machine.platform_uuid(ioreg({:ok, {"ioreg: not found\n", 127}})) == {:error, "ioreg exited with status 127: ioreg: not found"}
    assert Machine.platform_uuid(ioreg({:error, :timeout})) == {:error, "ioreg could not run: :timeout"}
  end

  test "reads this host's UUID only on a Mac" do
    assert Machine.local_uuid({:unix, :darwin}, ioreg(output(@uuid))) == {:ok, @uuid}
    assert_received {:cmd, "/usr/sbin/ioreg", _args, _opts}
    assert Machine.local_uuid({:unix, :linux}, ioreg(output(@uuid))) == {:ok, nil}
    assert Machine.local_uuid({:unix, :linux}) == {:ok, nil}
    refute_received {:cmd, _executable, _args, _opts}
  end

  test "the QA host is this host only when both UUIDs match" do
    assert Machine.same_machine?(ioreg(output(@uuid)), fn -> {:ok, @uuid} end) == {:ok, true}
    assert Machine.same_machine?(ioreg(output("99999999-8888-7777-6666-555544443333")), fn -> {:ok, @uuid} end) == {:ok, false}
    # A Symphony host that is not a Mac is never the QA host.
    assert Machine.same_machine?(ioreg(output(@uuid)), fn -> {:ok, nil} end) == {:ok, false}

    assert Machine.same_machine?(ioreg({:error, :timeout}), fn -> {:ok, @uuid} end) ==
             {:error, "the hardware UUID of the QA host could not be read: ioreg could not run: :timeout"}

    assert Machine.same_machine?(ioreg(output(@uuid)), fn -> {:error, "ioreg printed no IOPlatformUUID"} end) ==
             {:error, "the hardware UUID of this host could not be read: ioreg printed no IOPlatformUUID"}
  end

  defp displays(displays), do: {:ok, {Jason.encode!(%{"SPDisplaysDataType" => [%{"sppci_model" => "Apple Paravirtual device", "spdisplays_ndrvs" => displays}]}), 0}}

  test "reads the main display's size in points, as it looks, not its pixels" do
    retina = %{"_name" => "Retina", "_spdisplays_pixels" => "2560 x 1440", "_spdisplays_resolution" => "1280 x 720 @ 60.00Hz"}
    full = %{"_name" => "Display", "_spdisplays_pixels" => "2560 x 1440", "_spdisplays_resolution" => "2560 x 1440 @ 60.00Hz"}

    assert Machine.screen_points(ioreg(displays([full]))) == {:ok, {2560, 1440}}
    assert_received {:cmd, "/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], opts}
    assert opts[:timeout_ms] == 30_000

    assert Machine.screen_points(ioreg(displays([full, Map.put(retina, "spdisplays_main", "spdisplays_yes")]))) == {:ok, {1280, 720}}
    assert Machine.screen_points(ioreg(displays([retina, full]))) == {:ok, {1280, 720}}
  end

  test "says when it can't read a display size" do
    assert Machine.screen_points(ioreg(displays([]))) == {:error, "system_profiler reported no display size"}
    assert Machine.screen_points(ioreg(displays([%{"_spdisplays_resolution" => "unknown"}]))) == {:error, "system_profiler reported no display size"}
    assert Machine.screen_points(ioreg({:ok, {"not json", 0}})) == {:error, "system_profiler reported no display size"}
    assert Machine.screen_points(ioreg({:ok, {~s({"SPDisplaysDataType": [{"sppci_model": "none"}]}), 0}})) == {:error, "system_profiler reported no display size"}
    assert Machine.screen_points(ioreg({:ok, {"denied\n", 1}})) == {:error, "system_profiler exited with status 1: denied"}
    assert Machine.screen_points(ioreg({:error, :timeout})) == {:error, "system_profiler could not run: :timeout"}
  end
end
