defmodule SymphonyElixir.AgentCaches do
  @moduledoc """
  The per-user folder where a local agent keeps the Elixir tool caches its
  sandbox can't write on the host.

  The sandbox only lets an agent write its workspace and a few folders, so
  Hex (`~/.hex`), `elixir_make` (`~/Library/Caches/elixir_make`) and
  Dialyxir's core PLTs (in `MIX_HOME`) fail there. A local agent instead gets
  one folder Symphony owns, `~/Library/Caches/symphony/agent` on macOS
  (`$XDG_CACHE_HOME/symphony/agent` or `~/.cache/symphony/agent` elsewhere),
  shared by every run so downloads are reused. Its sandbox may write there, and
  its env points the tools at it:

    * `HEX_HOME` is `<folder>/hex`;
    * `ELIXIR_MAKE_CACHE_DIR` is `<folder>/elixir_make`;
    * `SYMPHONY_AGENT_CACHE_DIR` is the folder, for a repo's own tools (this
      repo's `mix.exs` keeps Dialyxir's core PLTs there).

  The host's caches stay read-only to the agent. Before each launch Symphony
  copies into the folder what they hold that it lacks: Hex's registry cache
  (`cache.ets`) and package tarballs, and `elixir_make`'s precompiled archives,
  so deps the host fetched still resolve offline. Hex and `elixir_make` check
  each file against `mix.lock` and the package's checksums before using it.
  Hex's `hex.config` is never copied: it can hold API and repo keys.

  The agent can write the folder, so Symphony, which runs outside the sandbox,
  never writes through a link in it: it only uses folders that are plain
  directories, only copies regular files, and writes each copy to a new file it
  then renames into place. When the folder itself is not a plain directory, the
  agent gets neither the env nor the write access.
  """

  alias SymphonyElixir.PathSafety

  @app :symphony_elixir
  @config_key :agent_caches

  @typedoc "Where the folder is and the host caches it is seeded from."
  @type config :: %{root: Path.t(), host_hex_home: Path.t(), host_elixir_make_cache: Path.t()}

  @doc """
  The folders a local agent's sandbox may write for its caches: the folder,
  once it is a plain directory, else none. The path has its links resolved, as
  sandboxes match the real path a write goes to.
  """
  @spec write_paths() :: [Path.t()]
  def write_paths, do: write_paths(config())

  @doc false
  @spec write_paths(config()) :: [Path.t()]
  def write_paths(%{root: root}) do
    with true <- ensure_root(root),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      [canonical_root]
    else
      _unusable -> []
    end
  end

  @doc """
  Seeds the folder from the host caches and returns the env that points a local
  agent's tools at it, or an empty env when the folder can't be used.
  """
  @spec env() :: %{String.t() => String.t()}
  def env, do: env(config())

  @doc false
  @spec env(config()) :: %{String.t() => String.t()}
  def env(%{root: root} = config) do
    if ensure_root(root) do
      hex_home = Path.join(root, "hex")
      elixir_make_cache = Path.join(root, "elixir_make")

      seed_hex(config.host_hex_home, hex_home)

      if plain_directory?(elixir_make_cache) do
        copy_missing_files(config.host_elixir_make_cache, elixir_make_cache)
      end

      %{
        "HEX_HOME" => hex_home,
        "ELIXIR_MAKE_CACHE_DIR" => elixir_make_cache,
        "SYMPHONY_AGENT_CACHE_DIR" => root
      }
    else
      %{}
    end
  end

  @doc false
  @spec config() :: config()
  def config, do: config(Application.get_env(@app, @config_key, []), System.get_env())

  @doc false
  @spec config(keyword(), %{optional(String.t()) => String.t()}) :: config()
  def config(overrides, host_env) do
    %{
      root: Keyword.get_lazy(overrides, :root, fn -> Path.join(:filename.basedir(:user_cache, "symphony"), "agent") end),
      host_hex_home:
        Keyword.get_lazy(overrides, :host_hex_home, fn ->
          env_path(host_env, "HEX_HOME") || Path.join(System.user_home!(), ".hex")
        end),
      host_elixir_make_cache:
        Keyword.get_lazy(overrides, :host_elixir_make_cache, fn ->
          env_path(host_env, "ELIXIR_MAKE_CACHE_DIR") || :filename.basedir(:user_cache, "elixir_make")
        end)
    }
  end

  defp env_path(host_env, name) do
    case Map.get(host_env, name) do
      value when value in [nil, ""] -> nil
      value -> Path.expand(value)
    end
  end

  defp ensure_root(root) do
    # The folder's parent is Symphony's, outside any sandbox, so it is safe to create.
    _ = File.mkdir_p(Path.dirname(root))
    plain_directory?(root)
  end

  defp seed_hex(host_hex_home, hex_home) do
    if plain_directory?(hex_home) do
      copy_missing_file(Path.join(host_hex_home, "cache.ets"), Path.join(hex_home, "cache.ets"))

      host_packages = Path.join(host_hex_home, "packages")
      packages = Path.join(hex_home, "packages")

      # One folder per Hex repo (`hexpm`, `hexpm:<org>`), each holding tarballs.
      with {:ok, repos} <- File.ls(host_packages), true <- plain_directory?(packages) do
        Enum.each(repos, &copy_missing_files(Path.join(host_packages, &1), Path.join(packages, &1)))
      end
    end

    :ok
  end

  defp copy_missing_files(source_dir, dest_dir) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(source_dir),
         {:ok, names} <- File.ls(source_dir),
         true <- plain_directory?(dest_dir) do
      Enum.each(names, &copy_missing_file(Path.join(source_dir, &1), Path.join(dest_dir, &1)))
    end

    :ok
  end

  defp copy_missing_file(source, dest) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(source),
         {:error, :enoent} <- File.lstat(dest) do
      copy_new(source, dest)
    end

    :ok
  end

  # Another launch may copy the same file at once, and an agent may read it, so the copy is
  # written to a file of its own (`:exclusive` never opens an existing path, a link included)
  # and renamed into place whole. A rename replaces a link the agent made meanwhile rather
  # than writing through it.
  defp copy_new(source, dest) do
    tmp = Path.join(Path.dirname(dest), ".#{Path.basename(dest)}.#{System.unique_integer([:positive])}.tmp")

    with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
         {:ok, _bytes} <- copy_and_close(source, io),
         :ok <- File.rename(tmp, dest) do
      :ok
    else
      _error -> File.rm(tmp)
    end
  end

  defp copy_and_close(source, io) do
    :file.copy(source, io)
  after
    File.close(io)
  end

  defp plain_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      {:error, :enoent} -> File.mkdir(path) == :ok
      _other -> false
    end
  end
end
