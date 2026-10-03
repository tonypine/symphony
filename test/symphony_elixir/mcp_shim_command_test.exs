defmodule SymphonyElixir.McpShimCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.McpShimCommand

  test "runs the shim with this VM's erl and Elixir" do
    {command, args} = McpShimCommand.build("/tmp/shim", ["--socket", "/tmp/sock"])

    assert command == Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "bin", "erl"])
    assert File.regular?(command)
    assert ["-noshell" | _rest] = args
    assert Enum.take(args, -9) == ["-pa", elixir_ebin(), "-s", "elixir", "start_cli", "-extra", "/tmp/shim", "--socket", "/tmp/sock"]
  end

  test "falls back to the shim itself when this VM's erl is missing" do
    vm = %{McpShimCommand.vm() | erl: "/nonexistent/erl"}

    assert McpShimCommand.build("/tmp/shim", ["--socket", "/tmp/sock"], vm) == {"/tmp/shim", ["--socket", "/tmp/sock"]}
  end

  test "a release VM boots the shim clean with the release's boot vars" do
    root = Path.join(System.tmp_dir!(), "symphony-shim-command-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    releases_dir = Path.join([root, "releases", "0.0.1"])
    File.mkdir_p!(releases_dir)
    File.write!(Path.join(releases_dir, "start_clean.boot"), "")

    vm =
      McpShimCommand.vm(
        root_dir: root,
        boot: {:ok, [[String.to_charlist(Path.join(releases_dir, "start"))]]},
        boot_var: {:ok, [[~c"RELEASE_LIB", String.to_charlist(Path.join(root, "lib"))]]}
      )

    assert vm.erl == Path.join([root, "erts-#{:erlang.system_info(:version)}", "bin", "erl"])
    assert vm.boot == Path.join(releases_dir, "start_clean")
    assert vm.boot_vars == [{"RELEASE_LIB", Path.join(root, "lib")}]

    {_command, args} = McpShimCommand.build("/tmp/shim", [], %{vm | erl: elixir_erl()})

    assert Enum.take(args, 7) == [
             "-noshell",
             "-boot",
             Path.join(releases_dir, "start_clean"),
             "-boot_var",
             "RELEASE_LIB",
             Path.join(root, "lib"),
             "-pa"
           ]
  end

  test "a boot without a clean boot file next to it and no boot args leave erl's default boot" do
    vm = McpShimCommand.vm(boot: {:ok, [[~c"/nonexistent/releases/0.0.1/start"]]}, boot_var: :error)
    assert vm.boot == nil
    assert vm.boot_vars == []

    assert McpShimCommand.vm(boot: :error).boot == nil
  end

  defp elixir_ebin, do: Path.join(to_string(:code.lib_dir(:elixir)), "ebin")

  defp elixir_erl, do: McpShimCommand.vm().erl
end
