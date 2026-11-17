defmodule SymphonyElixir.Harnesses.LauncherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Harnesses
  alias SymphonyElixir.Harnesses.Launcher

  test "each harness has the module that starts its sessions" do
    assert Launcher.module!("claude") == SymphonyElixir.ClaudeCode.AppServer
    assert Launcher.module!("codex") == SymphonyElixir.Codex.AppServer
    assert Launcher.module!("opencode") == SymphonyElixir.Opencode.AppServer

    for harness <- Harnesses.ids(), do: assert(is_atom(Launcher.module!(harness)))
  end

  test "a harness no one registered raises" do
    assert_raise KeyError, fn -> Launcher.module!("gpt") end
  end
end
