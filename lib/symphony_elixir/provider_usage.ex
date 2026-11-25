defmodule SymphonyElixir.ProviderUsage do
  @moduledoc """
  When Symphony reads a provider's usage from the provider itself, rather than from its runs'
  events (TP-1642). Only OpenCode Go has such a source (`SymphonyElixir.OpencodeGo.Usage`);
  Anthropic's windows come from Claude Code's rate-limit events.

  There is no poller. The orchestrator asks for a read at boot, when a run on the provider starts
  and ends, and on that run's worker updates while it works, at most once a minute
  (`request/4`). The read runs in a task under `SymphonyElixir.TaskSupervisor`, which sends the
  orchestrator `{:provider_usage_read, provider, result}`; the orchestrator keeps the windows under
  the provider (`SymphonyElixir.UsageLimit.remember_windows/3`) and holds it at its reserve as it
  does Anthropic. A failed read keeps the last windows and holds or fails nothing.
  """

  require Logger

  alias SymphonyElixir.OpencodeGo

  @min_interval_seconds 60

  @typedoc "When each provider's last read started, by provider."
  @type read_at :: %{optional(String.t()) => DateTime.t()}

  @doc "The providers whose usage Symphony reads from the provider itself."
  @spec providers() :: [String.t()]
  def providers, do: [OpencodeGo.Usage.provider()]

  @doc """
  Starts a read of `provider`'s usage, unless Symphony reads none from it, or (`force: false`, a
  worker update) a read started less than a minute before `now`. Returns `read_at` with the read's
  start. Options: `force` (default `false`), `recipient` (default the caller), and for tests
  `reader`, a `(provider -> {:ok, windows} | {:error, reason})` function (else the
  `:provider_usage_reader` app env's, else `read/1`), and `supervisor`.
  """
  @spec request(read_at(), String.t() | nil, DateTime.t(), keyword()) :: read_at()
  def request(read_at, provider, %DateTime{} = now, opts \\ []) when is_map(read_at) do
    cond do
      provider not in providers() ->
        read_at

      not Keyword.get(opts, :force, false) and recent?(Map.get(read_at, provider), now) ->
        read_at

      true ->
        start(provider, opts)
        Map.put(read_at, provider, now)
    end
  end

  @doc "Reads `provider`'s usage now, in the caller."
  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read("opencode-go"), do: OpencodeGo.Usage.read()

  @doc """
  Logs a failed read per `docs/logging.md`; a provider whose key is not set is not an error (it
  has nothing to read with), so it is a debug line.
  """
  @spec log_failure(String.t(), term()) :: :ok
  def log_failure(provider, :no_key) do
    Logger.debug("Provider usage not read provider=#{provider} reason=#{inspect(OpencodeGo.Usage.format_reason(:no_key))}")
  end

  def log_failure(provider, reason) do
    Logger.warning("Provider usage read failed; keeping the last windows provider=#{provider} reason=#{inspect(OpencodeGo.Usage.format_reason(reason))}")
  end

  defp recent?(%DateTime{} = last, now), do: DateTime.diff(now, last, :second) < @min_interval_seconds
  defp recent?(nil, _now), do: false

  defp start(provider, opts) do
    recipient = Keyword.get(opts, :recipient, self())
    reader = Keyword.get(opts, :reader) || Application.get_env(:symphony_elixir, :provider_usage_reader, &read/1)
    task = fn -> send(recipient, {:provider_usage_read, provider, reader.(provider)}) end

    # A read that can't start is skipped like a failed one; the next trigger tries again.
    _started = Task.Supervisor.start_child(Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor), task)
    :ok
  catch
    :exit, reason -> Logger.warning("Provider usage read not started provider=#{provider} reason=#{inspect(reason)}")
  end
end
