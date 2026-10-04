defmodule SymphonyElixir.McpShimCommand do
  @moduledoc """
  Builds the command that starts the Symphony MCP shim on this host.

  The shim is an Elixir script. Run on its own, its `#!/usr/bin/env elixir` line
  takes the first `elixir` on PATH, which is often a mise shim. mise picks the
  version from the agent's workspace, so in a repo that pins no Elixir the shim
  never starts. Running it with the ERTS and Elixir of the VM Symphony runs on
  needs neither PATH nor a version manager, from a checkout and from the
  release alike.

  The command is ERTS's `erlexec`, the launcher `erl` wraps. A Burrito release
  ships `erlexec` but no `erl` script, so `erlexec` gets the environment `erl`
  would set: `ROOTDIR`, `BINDIR`, `EMU` and `PROGNAME`.
  """

  require Logger

  @type vm :: %{
          root: Path.t(),
          erts_bin: Path.t(),
          elixir_ebin: Path.t(),
          boot: Path.t() | nil,
          boot_vars: [{String.t(), String.t()}]
        }

  @type command :: {Path.t(), [String.t()], %{String.t() => String.t()}}

  @doc """
  Returns `{command, args, env}` that run `shim_path` with `shim_args`.

  Falls back to running the shim itself, with a warning, when this VM's
  `erlexec` or Elixir code path can't be found.
  """
  @spec build(Path.t(), [String.t()]) :: command()
  def build(shim_path, shim_args), do: build(shim_path, shim_args, vm())

  @spec build(Path.t(), [String.t()], vm()) :: command()
  def build(shim_path, shim_args, %{erts_bin: erts_bin, elixir_ebin: elixir_ebin} = vm) do
    erlexec = Path.join(erts_bin, "erlexec")

    cond do
      not File.regular?(erlexec) ->
        shim_fallback(shim_path, shim_args, erlexec)

      not File.dir?(elixir_ebin) ->
        shim_fallback(shim_path, shim_args, elixir_ebin)

      true ->
        args =
          ["-noshell"] ++
            boot_args(vm) ++
            ["-pa", elixir_ebin, "-s", "elixir", "start_cli", "-extra", shim_path | shim_args]

        {erlexec, args, %{"ROOTDIR" => vm.root, "BINDIR" => erts_bin, "EMU" => "beam", "PROGNAME" => "erl"}}
    end
  end

  defp shim_fallback(shim_path, shim_args, missing) do
    Logger.warning("Symphony MCP shim falls back to the elixir on PATH; not found: #{missing} shim_path=#{shim_path}")
    {shim_path, shim_args, %{}}
  end

  @doc """
  Describes the running VM. Options override what `:init` and `:code` report,
  for tests.
  """
  @spec vm(keyword()) :: vm()
  def vm(opts \\ []) do
    root = Keyword.get_lazy(opts, :root_dir, fn -> to_string(:code.root_dir()) end)
    elixir_lib = Keyword.get_lazy(opts, :elixir_lib_dir, fn -> to_string(:code.lib_dir(:elixir)) end)

    %{
      root: root,
      erts_bin: Path.join([root, "erts-#{:erlang.system_info(:version)}", "bin"]),
      elixir_ebin: Path.join(elixir_lib, "ebin"),
      boot: opts |> Keyword.get_lazy(:boot, fn -> :init.get_argument(:boot) end) |> clean_boot(),
      boot_vars: opts |> Keyword.get_lazy(:boot_var, fn -> :init.get_argument(:boot_var) end) |> boot_vars()
    }
  end

  # A release boots its own app from `releases/<vsn>/start`; the `start_clean`
  # next to it loads only kernel and stdlib. A plain `erl` has no `-boot`
  # argument and its default boot already is clean.
  defp clean_boot({:ok, [[boot | _rest] | _more]}) do
    clean_boot = Path.join(Path.dirname(to_string(boot)), "start_clean")
    if File.regular?(clean_boot <> ".boot"), do: clean_boot
  end

  defp clean_boot(_boot), do: nil

  # A release's boot scripts locate the apps through `$RELEASE_LIB`.
  defp boot_vars({:ok, values}) do
    for [name, dir] <- values, do: {to_string(name), to_string(dir)}
  end

  defp boot_vars(_boot_var), do: []

  defp boot_args(%{boot: boot, boot_vars: boot_vars}) do
    boot_flag = if boot, do: ["-boot", boot], else: []
    boot_flag ++ Enum.flat_map(boot_vars, fn {name, dir} -> ["-boot_var", name, dir] end)
  end
end
