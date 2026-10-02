defmodule SymphonyElixir.ReleaseCookie do
  @moduledoc """
  Resolves the Erlang distribution cookie at release boot.

  Distribution itself is only used for local remote-console/observer access; the
  control plane is HTTP (see `SymphonyElixir.ControlClient`). The cookie is still
  a shared secret that grants full code execution to any node that connects, so it
  must be unguessable and owner-only.

  The `bin/symphony` script applies this cookie via `rel/env.sh.eex` before the VM
  boots. The Burrito-packaged binary boots the BEAM directly and never sources
  `env.sh`, so for that launch path `runtime.exs` resolves the same value via
  `resolve!/0` and `SymphonyElixir.ReleaseNode` applies it when the service starts
  distribution. Both paths converge on the same persisted value, so a daemon
  started either way accepts a `bin/symphony remote` shell.

  Resolution mirrors `rel/env.sh.eex`:

    * `SYMPHONY_COOKIE`, when set, is used verbatim and the state-root file is left
      untouched.
    * otherwise the cookie is read from `Paths.erlang_cookie_file/0`, requiring
      owner-only permissions, or generated and persisted with `0600` on first boot.

  The legacy static cookie `"symphony"` is rejected.
  """

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.Paths

  @cookie_bytes 32
  @insecure_cookie "symphony"

  @doc """
  Returns the cookie to use, generating and persisting one on first boot.

  Raises if the resolved cookie is empty, insecure, or read from a file that is
  not owner-only — failing closed, exactly as `rel/env.sh.eex` does.
  """
  @spec resolve!() :: String.t()
  def resolve! do
    case System.get_env("SYMPHONY_COOKIE") do
      cookie when cookie in [nil, ""] -> from_state_root()
      cookie -> validate!(cookie)
    end
  end

  defp from_state_root do
    path = Paths.erlang_cookie_file()
    if File.exists?(path), do: read_existing!(path), else: create!(path)
  end

  defp read_existing!(path) do
    mode = File.stat!(path).mode

    if band(mode, 0o077) != 0 do
      raise "#{path} must be readable only by its owner; got mode #{Integer.to_string(band(mode, 0o777), 8)}."
    end

    path
    |> File.read!()
    |> String.trim()
    |> validate!()
  end

  defp create!(path) do
    cookie = validate!(generate())
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)
    File.write!(path, cookie <> "\n")
    _ = File.chmod(path, 0o600)
    cookie
  end

  defp validate!(cookie) do
    cond do
      cookie == "" -> raise "Erlang distribution cookie is empty."
      cookie == @insecure_cookie -> raise ~s(Refusing to use insecure Erlang distribution cookie "#{@insecure_cookie}".)
      true -> cookie
    end
  end

  defp generate do
    @cookie_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
