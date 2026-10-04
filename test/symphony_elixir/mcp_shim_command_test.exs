defmodule SymphonyElixir.McpShimCommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.McpShimCommand

  @erts "erts-#{:erlang.system_info(:version)}"

  test "runs the shim with this VM's erlexec and Elixir" do
    root = to_string(:code.root_dir())
    erts_bin = Path.join([root, @erts, "bin"])

    {command, args, env} = McpShimCommand.build("/tmp/shim", ["--socket", "/tmp/sock"])

    assert command == Path.join(erts_bin, "erlexec")
    assert File.regular?(command)
    assert ["-noshell" | _rest] = args
    assert Enum.take(args, -9) == ["-pa", elixir_ebin(), "-s", "elixir", "start_cli", "-extra", "/tmp/shim", "--socket", "/tmp/sock"]
    assert env == %{"ROOTDIR" => root, "BINDIR" => erts_bin, "EMU" => "beam", "PROGNAME" => "erl"}
  end

  test "a release without an erl script boots the shim clean through erlexec" do
    root = tmp_root()
    erts_bin = Path.join([root, @erts, "bin"])
    releases_dir = Path.join([root, "releases", "0.0.1-127"])
    elixir_lib = Path.join([root, "lib", "elixir-#{System.version()}"])

    for dir <- [erts_bin, releases_dir, Path.join(elixir_lib, "ebin")], do: File.mkdir_p!(dir)
    for file <- ["erlexec", "erl.src", "dyn_erl", "beam.smp"], do: File.write!(Path.join(erts_bin, file), "")
    File.write!(Path.join(releases_dir, "start_clean.boot"), "")

    vm =
      McpShimCommand.vm(
        root_dir: root,
        elixir_lib_dir: elixir_lib,
        boot: {:ok, [[String.to_charlist(Path.join(releases_dir, "start"))]]},
        boot_var: {:ok, [[~c"RELEASE_LIB", String.to_charlist(Path.join(root, "lib"))]]}
      )

    assert McpShimCommand.build("/tmp/shim", ["--socket", "/tmp/sock"], vm) ==
             {Path.join(erts_bin, "erlexec"),
              [
                "-noshell",
                "-boot",
                Path.join(releases_dir, "start_clean"),
                "-boot_var",
                "RELEASE_LIB",
                Path.join(root, "lib"),
                "-pa",
                Path.join(elixir_lib, "ebin"),
                "-s",
                "elixir",
                "start_cli",
                "-extra",
                "/tmp/shim",
                "--socket",
                "/tmp/sock"
              ], %{"ROOTDIR" => root, "BINDIR" => erts_bin, "EMU" => "beam", "PROGNAME" => "erl"}}
  end

  test "falls back to the shim itself, with a warning, when erlexec or Elixir's ebin is missing" do
    root = tmp_root()
    no_erlexec = McpShimCommand.vm(root_dir: root)

    log =
      capture_log(fn ->
        assert McpShimCommand.build("/tmp/shim", ["--socket", "/tmp/sock"], no_erlexec) == {"/tmp/shim", ["--socket", "/tmp/sock"], %{}}
      end)

    assert log =~ "Symphony MCP shim falls back to the elixir on PATH; not found: #{Path.join([root, @erts, "bin", "erlexec"])}"

    no_ebin = McpShimCommand.vm(elixir_lib_dir: Path.join(root, "elixir"))

    log =
      capture_log(fn ->
        assert McpShimCommand.build("/tmp/shim", [], no_ebin) == {"/tmp/shim", [], %{}}
      end)

    assert log =~ "not found: #{Path.join([root, "elixir", "ebin"])}"
  end

  test "a boot without a clean boot file next to it and no boot args leave erl's default boot" do
    vm = McpShimCommand.vm(boot: {:ok, [[~c"/nonexistent/releases/0.0.1/start"]]}, boot_var: :error)
    assert vm.boot == nil
    assert vm.boot_vars == []

    assert McpShimCommand.vm(boot: :error).boot == nil
  end

  defp elixir_ebin, do: Path.join(to_string(:code.lib_dir(:elixir)), "ebin")

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "symphony-shim-command-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
