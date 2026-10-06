defmodule SymphonyElixir.GitDiffDriverGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitConfigCommands

  # A host-side git that prints a diff runs the diff drivers the repo's config names, unless
  # `GitConfigCommands.subcommand_args/1` adds `--no-ext-diff --no-textconv`. So every place in
  # `lib/` that starts git hands it its arguments through that helper, or is listed here with
  # the reason it doesn't need to.
  @runners %{
    {"lib/symphony_elixir/workspace.ex", "safe_git"} => "`Workspace.safe_git/3` adds `subcommand_args/1` itself",
    {"lib/symphony_elixir/workspace.ex", "read_git"} => "reads the config for `config_args/3`, and runs the command with `subcommand_args/1` in `safe_git_stdout/1`",
    {"lib/symphony_elixir/dependency_audit.ex", "command_runner."} => "the runner defaults to `Workspace.safe_git/3`",
    {"lib/mix/tasks/workspace.before_remove.ex", "run_command"} => "it only runs `git remote get-url`, which prints no diff"
  }

  # A call that hands a runner the git executable by name (`System.cmd("git", ...)`,
  # `command_runner.("git", ...)`), or starts git from a path: `System.cmd(git, ...)`,
  # `Port.open({:spawn_executable, git}, ...)`, `:os.cmd('git ...')`.
  @git_start ~r/(?<callee>[\w.!?]+)\(\s*"git"\s*,|System\.cmd\(\s*git\s*,|spawn_executable,\s*(?:"git"|git)\b|:os\.cmd\(.*\bgit\b/

  test "lib/ starts git only through the helper that turns off diff drivers" do
    violations =
      for path <- Path.wildcard("lib/**/*.ex") |> Enum.sort(),
          violation <- violations(path, File.read!(path)),
          do: violation

    assert violations == [], """
    These lines start git without `SymphonyElixir.GitConfigCommands.subcommand_args/1`, so a diff
    they print would run the repo's diff drivers. Pass the arguments through it, or run git with
    `SymphonyElixir.Workspace.safe_git/3`:

    #{Enum.join(violations, "\n")}
    """
  end

  test "every listed runner still starts git where the list says" do
    for {{path, callee}, _reason} <- @runners do
      callees = for line <- code_lines(File.read!(path)), %{"callee" => name} <- [Regex.named_captures(@git_start, line)], do: name
      assert callee in callees, "#{path} no longer starts git through #{callee}; drop it from @runners"
    end
  end

  test "the guard catches a git call that skips the helper, and passes one that uses it" do
    source = """
    defmodule Sample do
      # System.cmd("git", ["log", "-p"]) in a comment starts nothing.
      def blame(file), do: System.cmd("git", ["blame", file])
      def patch(git), do: System.cmd(git, ["format-patch", "-1"])
      def spawn(git), do: Port.open({:spawn_executable, git}, args: ["show"])
      def range, do: :os.cmd(~c"git range-diff a b")
      def diff(args), do: System.cmd("git", GitConfigCommands.subcommand_args(["diff" | args]))
    end
    """

    assert violations("lib/sample.ex", source) == [
             ~S|lib/sample.ex:3: def blame(file), do: System.cmd("git", ["blame", file])|,
             ~S|lib/sample.ex:4: def patch(git), do: System.cmd(git, ["format-patch", "-1"])|,
             ~S|lib/sample.ex:5: def spawn(git), do: Port.open({:spawn_executable, git}, args: ["show"])|,
             ~S|lib/sample.ex:6: def range, do: :os.cmd(~c"git range-diff a b")|
           ]

    assert GitConfigCommands.subcommand_args(["blame", "f"]) == ["blame", "--no-ext-diff", "--no-textconv", "f"]
  end

  defp violations(path, source) do
    for {line, number} <- source |> String.split("\n") |> Enum.with_index(1),
        not comment?(line),
        Regex.match?(@git_start, line),
        not String.contains?(line, "subcommand_args("),
        not listed_runner?(path, line),
        do: "#{path}:#{number}: #{String.trim(line)}"
  end

  defp listed_runner?(path, line) do
    case Regex.named_captures(@git_start, line) do
      %{"callee" => callee} -> Map.has_key?(@runners, {path, callee})
      nil -> false
    end
  end

  defp code_lines(source), do: source |> String.split("\n") |> Enum.reject(&comment?/1)

  defp comment?(line), do: line |> String.trim_leading() |> String.starts_with?("#")
end
