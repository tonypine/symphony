defmodule SymphonyElixir.ClaudeCode.AppLaunchHook do
  @moduledoc """
  The Claude Code `PreToolUse` hook that refuses a Bash command starting a macOS app
  (`priv/claude_hooks/app_launch_hook.pl`).

  The agent sandbox denies the window server, so an AppKit program can't draw, but it allows
  LaunchServices, and Claude Code has no setting to deny it. A program that checks in there is an
  app to ReportCrash, so when it crashes the operator's desktop gets a "quit unexpectedly" dialog:
  the `appkit-dialog` workflow showed it (TP-479). The hook keeps agents from starting one.

  Symphony writes the script next to the session's `settings.json` (on an SSH worker too) and runs
  it with `/usr/bin/perl`, which macOS ships. The script is embedded at compile time, like the
  shared skills.
  """

  @script_name "app-launch-hook.pl"
  @script_source Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "claude_hooks", "app_launch_hook.pl"]))
  @external_resource @script_source
  @script File.read!(@script_source)
  # Seconds Claude Code waits for the hook; it reads the program's file at most once.
  @timeout 10

  @doc "The `{path, contents}` pair of the hook script in the session's settings folder."
  @spec files(Path.t()) :: [{Path.t(), binary()}]
  def files(settings_dir) when is_binary(settings_dir), do: [{script_path(settings_dir), @script}]

  @doc "The `hooks` entry of the session's `settings.json`, running the script before each Bash command."
  @spec settings(Path.t()) :: map()
  def settings(settings_dir) when is_binary(settings_dir) do
    %{
      "PreToolUse" => [
        %{
          "matcher" => "Bash",
          "hooks" => [
            %{"type" => "command", "command" => command(script_path(settings_dir)), "timeout" => @timeout}
          ]
        }
      ]
    }
  end

  defp script_path(settings_dir), do: Path.join(settings_dir, @script_name)

  defp command(path), do: "/usr/bin/perl '" <> String.replace(path, "'", ~S('"'"')) <> "'"
end
