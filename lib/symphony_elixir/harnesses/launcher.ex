defmodule SymphonyElixir.Harnesses.Launcher do
  @moduledoc """
  The module that starts and drives a session on each harness (`SymphonyElixir.AgentBehaviour`).
  Every run, whatever its kind, finds its harness's launcher here.
  """

  @launchers %{
    "claude" => SymphonyElixir.ClaudeCode.AppServer,
    "codex" => SymphonyElixir.Codex.AppServer,
    "opencode" => SymphonyElixir.Opencode.AppServer
  }

  @doc """
  The launcher for `harness`. Loading `symphony.yml` only accepts the harnesses
  `SymphonyElixir.Harnesses` lists, and each has one, so an unknown harness raises.
  """
  @spec module!(String.t()) :: module()
  def module!(harness), do: Map.fetch!(@launchers, harness)
end
