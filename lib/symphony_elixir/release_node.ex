defmodule SymphonyElixir.ReleaseNode do
  @moduledoc """
  Starts Erlang distribution for the Symphony service in the Burrito binary.

  `rel/vm.args` names no node, so the binary boots without distribution and a
  one-off command such as `symphony check` can run next to a running Symphony.
  Only the long-running service takes the fixed name `symphony@127.0.0.1`: Mnesia
  tags the RunStore's disc_copies with `node()`, so the name must stay the same
  across restarts.

  Booting with `-name`, `erlexec` starts `epmd` before the VM; starting
  distribution later has to do the same. The secure cookie from
  `SymphonyElixir.ReleaseCookie` is applied once the node is alive.
  """

  alias SymphonyElixir.ReleaseCookie

  @node_name :"symphony@127.0.0.1"

  @type deps :: %{
          alive?: (-> boolean()),
          start_epmd: (-> term()),
          start_node: (node() -> {:ok, pid()} | {:error, term()}),
          cookie: (-> String.t()),
          set_cookie: (atom() -> true)
        }

  @doc """
  Makes this VM the `symphony@127.0.0.1` node (long names), unless it is already
  distributed (the `bin/symphony` script passes `--name` itself).
  """
  @spec start(deps()) :: :ok | {:error, String.t()}
  def start(deps) do
    if deps.alive?.() do
      :ok
    else
      _ = deps.start_epmd.()
      start_node(deps)
    end
  end

  defp start_node(deps) do
    case deps.start_node.(@node_name) do
      {:ok, _pid} ->
        true = deps.set_cookie.(String.to_atom(deps.cookie.()))
        :ok

      {:error, reason} ->
        {:error,
         "Could not start Erlang distribution as #{@node_name}. " <>
           "Is another Symphony already running? (#{inspect(reason)})"}
    end
  end

  @doc "The real distribution, `epmd` and cookie functions for `start/1`."
  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      alive?: &Node.alive?/0,
      start_epmd: &start_epmd/0,
      start_node: &Node.start/1,
      cookie: &ReleaseCookie.resolve!/0,
      set_cookie: &Node.set_cookie/1
    }
  end

  @doc """
  Starts `epmd` as a daemon from the ERTS `bin` directory the launcher exports as
  `BINDIR`. A no-op when `epmd` already runs; without `BINDIR`, `Node.start/1`
  reports the missing `epmd`.
  """
  @spec start_epmd(String.t() | nil) :: :ok
  def start_epmd(bindir \\ System.get_env("BINDIR")) do
    with true <- bindir not in [nil, ""],
         epmd = Path.join(bindir, "epmd"),
         true <- File.exists?(epmd) do
      {_output, _status} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
    end

    :ok
  end
end
