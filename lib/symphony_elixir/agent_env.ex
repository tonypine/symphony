defmodule SymphonyElixir.AgentEnv do
  @moduledoc """
  Builds the environment passed to an agent subprocess (`Port.open/2` `:env`).

  Erlang's `:env` option appends to the inherited environment — a child process
  spawned without an explicit list sees the full parent env. To prevent secrets
  like `LINEAR_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GH_TOKEN`,
  `GITHUB_TOKEN`, or `SSH_AUTH_SOCK` from reaching the agent (and being
  exfiltrated via a legitimate command), this module emits an explicit
  whitelist for safe vars plus `{name, false}` entries that remove every other
  inherited var.

  Provider credentials must reach the agent runtime through its own config
  files (`~/.codex/auth.json`, `~/.claude/.credentials.json`), not the process
  environment.

  `MIX_HOME`, `MIX_ARCHIVES`, and `HEX_HOME` pass through so agent shells use
  the same Hex and Rebar install as the host (for example the per-version
  `MIX_HOME` that `mise` exports) instead of prompting to install Hex. A local
  agent's `HEX_HOME` then points at a cache folder its sandbox may write (see
  `SymphonyElixir.AgentCaches`).

  A local agent in a Gradle project also gets its own Gradle daemon registry in
  its workspace (see `gradle_env/1`).
  """

  @agent_runtime_env "SYMPHONY_AGENT_RUNTIME"
  @agent_runtime_env_value "1"
  @gradle_daemon_dir ".gradle-daemons"
  @gradle_markers ~w(gradlew settings.gradle settings.gradle.kts)

  @passthrough ~w(
    PATH
    HOME
    USER
    LOGNAME
    LANG
    LC_ALL
    LC_CTYPE
    LC_MESSAGES
    TERM
    TMPDIR
    SHELL
    TZ
    SSL_CERT_FILE
    MIX_HOME
    MIX_ARCHIVES
    HEX_HOME
  )

  @doc """
  Returns the constant marker env var name used to identify an agent subprocess.
  """
  @spec runtime_marker_name() :: String.t()
  def runtime_marker_name, do: @agent_runtime_env

  @doc """
  Returns the constant marker env var value (`"1"`).
  """
  @spec runtime_marker_value() :: String.t()
  def runtime_marker_value, do: @agent_runtime_env_value

  @doc """
  Folders Symphony itself may create in an agent's workspace. Git ignores
  them, and the QA worktree's clean check skips what is in them (see
  `SymphonyElixir.QaDriver`).
  """
  @spec owned_dirs() :: [String.t()]
  def owned_dirs, do: [@gradle_daemon_dir]

  @doc """
  The env that keeps an agent's Gradle builds on daemons of its own.

  Gradle daemons detach, outlive the build and are shared through the
  `~/.gradle/daemon` registry. A daemon started inside one agent's sandbox can
  only write to that agent's workspace, so a build elsewhere it serves fails, and
  it runs on after the run. With the registry in `<workspace>/.gradle-daemons`,
  a daemon only serves builds started with the same registry, and its working
  folder, `<registry>/<version>`, is in the workspace, so the run's end stops it
  (see `SymphonyElixir.LeftoverProcesses`).

  Only a Gradle project gets a registry: a workspace with `gradlew`,
  `settings.gradle` or `settings.gradle.kts` at its root. Any other workspace,
  such as a QA worktree of a repo without Gradle, gets an empty env and no
  folder. In a Gradle project the folder is created with a `.gitignore` of `*`,
  so git never lists it.

  Symphony runs outside the sandbox, so it never writes through a link the
  workspace holds: the `.gitignore` is only created, never overwritten, and when
  `.gradle-daemons` is a symlink or a file the env is empty, so neither a write
  nor the registry leaves the workspace.
  """
  @spec gradle_env(Path.t()) :: %{String.t() => String.t()}
  def gradle_env(workspace) when is_binary(workspace) do
    registry = Path.join(workspace, @gradle_daemon_dir)

    if gradle_project?(workspace) and plain_directory?(registry) do
      # `:exclusive` fails on any existing path, a symlink included.
      _ = File.write(Path.join(registry, ".gitignore"), "*\n", [:exclusive])

      # Quoted, so `gradlew` keeps a path with spaces as one argument.
      %{"GRADLE_OPTS" => ~s("-Dorg.gradle.daemon.registry.base=#{registry}")}
    else
      %{}
    end
  end

  defp gradle_project?(workspace) do
    Enum.any?(@gradle_markers, &File.exists?(Path.join(workspace, &1)))
  end

  defp plain_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      {:error, :enoent} -> File.mkdir(path) == :ok
      _other -> false
    end
  end

  @doc """
  Builds the env list from the current process environment.
  """
  @spec build() :: [{charlist(), charlist() | false}]
  def build, do: build(System.get_env())

  @doc """
  Builds the env list from the current process environment plus explicit safe
  runtime overrides.
  """
  @spec build_with(%{optional(String.t()) => String.t()}) :: [{charlist(), charlist() | false}]
  def build_with(extra_env) when is_map(extra_env), do: build(System.get_env(), extra_env)

  @doc """
  Builds the env list from an explicit env map.

  Each whitelisted variable present in `env_source` becomes a
  `{charlist_name, charlist_value}` tuple. Every other variable is emitted as
  `{charlist_name, false}`, which tells Erlang's `Port.open/2` to strip it from
  the inherited environment. The runtime marker is always set last so it can
  override any value present in the source.
  """
  @spec build(%{optional(String.t()) => String.t()}) :: [{charlist(), charlist() | false}]
  def build(env_source) when is_map(env_source), do: build(env_source, %{})

  @doc """
  Builds the env list from an explicit env map plus explicit safe runtime
  overrides.
  """
  @spec build(%{optional(String.t()) => String.t()}, %{optional(String.t()) => String.t()}) :: [
          {charlist(), charlist() | false}
        ]
  def build(env_source, extra_env) when is_map(env_source) and is_map(extra_env) do
    {pass, strip} = Map.split(env_source, @passthrough)
    pass = Map.drop(pass, Map.keys(extra_env))

    strip_entries =
      strip
      |> Map.delete(@agent_runtime_env)
      |> Map.drop(Map.keys(extra_env))
      |> Map.keys()
      |> Enum.map(fn name -> {String.to_charlist(name), false} end)

    passthrough_entries =
      pass
      |> Map.delete(@agent_runtime_env)
      |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    override_entries =
      extra_env
      |> Enum.reject(fn {_name, value} -> not is_binary(value) end)
      |> Enum.map(fn {name, value} -> {String.to_charlist(to_string(name)), String.to_charlist(value)} end)

    marker = {String.to_charlist(@agent_runtime_env), String.to_charlist(@agent_runtime_env_value)}

    strip_entries ++ passthrough_entries ++ override_entries ++ [marker]
  end
end
