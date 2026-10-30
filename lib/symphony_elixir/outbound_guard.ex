defmodule SymphonyElixir.OutboundGuard do
  @moduledoc """
  The test environment's HTTP adapter: `config/config.exs` makes it Req's default adapter under
  `mix test`, so no test can reach a host other than this machine. A request to `127.0.0.1`,
  `localhost` or `::1` goes through `Req.Finch` as usual; any other host raises
  `SymphonyElixir.OutboundConnectionInTest`, naming the host and the module that made the
  request, before a connection opens. A test that stubs its requests (`plug:`, its own `adapter:`)
  never reaches it.

  It is compile-time config for the test env only: no shell variable and no `symphony.yml` turns
  it off, and the app never uses it.
  """

  alias SymphonyElixir.OutboundConnectionInTest

  @local_hosts ["127.0.0.1", "localhost", "::1", "[::1]"]

  @doc "Sends `request` through `Req.Finch` when its host is this machine, else raises."
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{url: %URI{host: host}} = request) do
    if local?(host), do: Req.Finch.run(request), else: raise(OutboundConnectionInTest, host: host, caller: caller())
  end

  @doc "Whether `host` is this machine, the only host a test may reach."
  @spec local?(String.t() | nil) :: boolean()
  def local?(host), do: host in @local_hosts

  # The first Symphony module up the stack, past this guard: the code that made the request.
  defp caller do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
    Enum.find_value(stacktrace, :unknown, fn {module, _function, _arity, _location} -> if caller_module?(module), do: module end)
  end

  defp caller_module?(module), do: module != __MODULE__ and String.starts_with?(Atom.to_string(module), "Elixir.SymphonyElixir")
end

defmodule SymphonyElixir.OutboundConnectionInTest do
  @moduledoc "A test tried to open a connection to a host other than this machine (`SymphonyElixir.OutboundGuard`)."

  defexception [:host, :caller]

  @impl true
  def message(%__MODULE__{host: host, caller: caller}) do
    "#{inspect(caller)} opened a connection to #{host} in a test. Tests reach only 127.0.0.1 and localhost: " <>
      "stub the request (a `plug:` or `adapter:` option, Req.Test, or a stub server on 127.0.0.1)."
  end
end
