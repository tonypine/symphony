defmodule SymphonyElixir.Setup.Check do
  @moduledoc """
  One Setup check. `SymphonyElixir.Setup` runs every check and lists the problems they return.

  A check that reads Linear says so with `needs_linear?/0`. Without a Linear API key it is not run
  and is listed under `not_checked` instead. When it returns `{:error, reason}` Linear could not be
  reached, so Setup keeps the Linear-side problems of the last run that reached it. A check that
  can't run for another reason returns `{:error, reason}` too, and is listed under `not_checked`.
  """

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Setup.{Problem, TeamCache}

  @typedoc """
  What a run hands every check: the running `symphony.yml` (`system` is nil when none loaded), its
  path, the team cache for Linear reads, and the time of the run.
  """
  @type context :: %{
          system: SystemSchema.t() | nil,
          symphony_path: Path.t(),
          team_cache: TeamCache.t(),
          now: DateTime.t()
        }

  @doc "A stable name, the start of each of its problems' ids."
  @callback id() :: String.t()

  @doc "What it checks, in plain words, for `not_checked`."
  @callback title() :: String.t()

  @doc "Whether it reads Linear."
  @callback needs_linear?() :: boolean()

  @callback run(context()) :: [Problem.t()] | {:error, term()}
end
