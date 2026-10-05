defmodule SymphonyElixir.ChangedCoverage.Runner do
  @moduledoc """
  The git, `mix test` and `:cover` calls behind `mix cover.changed` (`SymphonyElixir.ChangedCoverage`).

  Listed in `mix.exs`'s `test_coverage` `ignore_modules`: `coverage/1` restarts the `:cover`
  server, which inside a `mix test --cover` run would throw away the suite's own coverage.
  """

  # `:cover` comes from OTP's `:tools`, which Mix loads when a task needs it, not the app.
  @compile {:no_warn_undefined, :cover}

  @export_name "cover_changed"

  @doc """
  Runs git in the current directory: `{:ok, stdout}`, or `{:error, message}` on a non-zero exit.
  Git's stderr goes to the terminal, so warnings never mix into the file lists.
  """
  @spec git([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def git(args) do
    case System.cmd("git", args) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, "exit status #{status}"}
    end
  end

  @doc """
  Runs `mix test --cover` on `test_files` in the test environment, streaming its output, and
  exports the coverage to `cover/#{@export_name}.coverdata` instead of printing the whole app's report.
  """
  @spec run_tests([Path.t()]) :: :ok | {:error, String.t()}
  def run_tests(test_files) do
    File.rm(coverdata())
    args = ["test", "--cover", "--export-coverage", @export_name | test_files]

    case System.cmd("mix", args, env: [{"MIX_ENV", "test"}], into: IO.binstream(:stdio, :line), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, "mix test exited with status #{status}; fix the failing tests first"}
    end
  end

  @doc """
  Reads the coverage `run_tests/1` exported and returns `:cover.analyse(module, :coverage, :line)`
  for each module. Deletes the export afterwards, so a later `mix test.coverage` doesn't pick it up.
  """
  @spec coverage([module()]) :: %{module() => {:ok, list()} | {:error, term()}}
  def coverage(modules) do
    Mix.ensure_application!(:tools)
    _ = :cover.stop()
    {:ok, pid} = :cover.start()
    # `:cover` prints a notice for each analysis of imported data.
    {:ok, quiet} = StringIO.open("")
    Process.group_leader(pid, quiet)

    try do
      :ok = :cover.import(String.to_charlist(coverdata()))
      Map.new(modules, &{&1, :cover.analyse(&1, :coverage, :line)})
    after
      :cover.stop()
      File.rm(coverdata())
    end
  end

  defp coverdata, do: Path.join("cover", @export_name <> ".coverdata")
end
