defmodule SymphonyElixir.SetupBlock do
  @moduledoc """
  A run that failed in its own setup, before the agent's first turn: the verification dev server
  that would not build, start, pass its health check or be served on its port.

  Nothing changes between attempts of such a run, and its first error already names the cause, so
  the orchestrator does not retry it as a crash. `SymphonyElixir.AgentRunner` exits with
  `{:setup_block, cause}`, and the orchestrator sends the block to the self-heal lane
  (`SymphonyElixir.SelfHeal`), which files or reuses the fix ticket for the broken component and
  holds the ticket on it.

  A failure a retry can change stays on the crash retry path: a worker host that could not be
  reached (the retry may pick another host), a workspace hook that failed, the verification port
  pool running out while other runs hold its ports.
  """

  @typedoc "The runner's own error for a setup block, as `setup_block?/1` accepts it."
  @type cause :: {:verification_failed, term()}

  @doc "Whether a run's error is a setup block rather than a failure worth retrying."
  @spec setup_block?(term()) :: boolean()
  def setup_block?({:verification_failed, _cause}), do: true
  def setup_block?(_reason), do: false

  @doc """
  The self-heal outcome of a setup block: the cause the lane names the component and scope from,
  the reason its evidence gives, and the summary the hold reason gives in words.
  """
  @spec outcome(cause()) :: map()
  def outcome(cause) do
    summary = describe(cause)
    %{cause: cause, reason: "the run failed in its own setup, before the agent's first turn: " <> summary, summary: summary}
  end

  @doc "A setup block's cause in words, for the hold reason and the log."
  @spec describe(cause() | term()) :: String.t()
  def describe({:verification_failed, cause}), do: verification(cause)
  def describe(cause), do: inspect(cause)

  defp verification({:dev_server_build_failed, 127}),
    do: "verification.dev_server build failed with exit 127: a command it runs is not on the sandbox PATH"

  defp verification({:dev_server_build_failed, status}), do: "verification.dev_server build failed with exit #{status}"
  defp verification(:dev_server_build_timeout), do: "verification.dev_server build timed out"
  defp verification(:health_timeout), do: "verification.dev_server did not pass its health check in time"
  defp verification({:dev_server_exit, status}), do: "verification.dev_server exited with status #{status} before it was healthy"

  defp verification({:dev_server_not_on_socket, socket}),
    do: "verification.dev_server never listened on its unix socket #{socket}"

  defp verification({:loopback_bridge_unavailable, :eaddrinuse}),
    do: "Symphony could not serve the dev server on its verification port: the port is already in use (eaddrinuse)"

  defp verification({:loopback_bridge_unavailable, reason}),
    do: "Symphony could not serve the dev server on its verification port: #{inspect(reason)}"

  defp verification(cause), do: "verification.dev_server did not start: #{inspect(cause)}"
end
