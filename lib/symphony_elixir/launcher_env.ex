defmodule SymphonyElixir.LauncherEnv do
  @moduledoc """
  Clears what the release launcher (`rel/overlays/bin/symphony-app`) leaves in the service's own
  environment, so no child process inherits the bundled Erlang.

  The launcher execs the bundled `erts-*/bin/erl`, whose script exports `ROOTDIR`, `BINDIR`, `EMU`
  and `PROGNAME` and puts the release's `erts-*/bin` and `bin` first on `PATH`; the launcher itself
  exports `SYMPHONY_RELEASE_ROOT` and the `RELEASE_*` variables. A workspace hook, an agent or a QA
  run inherits them, so its `mix` or `erl` resolves to the bundled one and boots against the app's
  release root (`cannot get bootfile …/symphony-release/bin/start.boot`), and a Symphony checkout
  run there reads as the packaged service.

  `clear/1` runs once at startup, after `SymphonyElixir.CLI.maybe_configure_packaged_runtime/0`
  (which reads `BINDIR` to start `epmd`). It records that the service is a packaged build in
  `:running_as_release`, which `SymphonyElixir.Paths` reads instead of the variable, then unsets
  the variables and drops the release's directories from `PATH`. A service not started by the
  launcher, which sets no `SYMPHONY_RELEASE_ROOT`, is left as it is.
  """

  @app :symphony_elixir
  @release_root_env "SYMPHONY_RELEASE_ROOT"
  @launcher_vars ~w(
    ROOTDIR
    BINDIR
    EMU
    PROGNAME
    RELEASE_ROOT
    RELEASE_NAME
    RELEASE_VSN
    RELEASE_SYS_CONFIG
    RELEASE_TMP
    SYMPHONY_RELEASE_ROOT
  )

  @doc """
  Clears the launcher's variables and the release's `PATH` entries from the OS environment when
  `env` names a release root. `env` defaults to the current OS environment.
  """
  @spec clear(%{optional(String.t()) => String.t()}) :: :ok
  def clear(env \\ System.get_env()) do
    case Map.get(env, @release_root_env) do
      root when is_binary(root) and root != "" ->
        Application.put_env(@app, :running_as_release, true)
        Enum.each(@launcher_vars, &System.delete_env/1)
        System.put_env("PATH", build_path_without_release(Map.get(env, "PATH", ""), root))

      _not_launched ->
        :ok
    end
  end

  @doc "`path` without the entries inside `release_root`, in their order."
  @spec build_path_without_release(String.t(), String.t()) :: String.t()
  def build_path_without_release(path, release_root) do
    root = Path.expand(release_root)

    path
    |> String.split(":")
    |> Enum.reject(&inside?(&1, root))
    |> Enum.join(":")
  end

  defp inside?("", _root), do: false

  defp inside?(entry, root) do
    expanded = Path.expand(entry)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end
end
