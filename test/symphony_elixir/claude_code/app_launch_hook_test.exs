defmodule SymphonyElixir.ClaudeCode.AppLaunchHookTest do
  # Runs the hook script the way Claude Code does, with the tool call as JSON on stdin, against
  # stand-in Mach-O files: the Mach-O magic and the names the script looks for. The `appkit_dialog`
  # test runs it against the compiled AppKit probe on a macOS runner.
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.AppLaunchHook

  @macho <<0xCF, 0xFA, 0xED, 0xFE>>

  setup do
    root = Path.join(System.tmp_dir!(), "app-launch-hook-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    [{script, contents}] = AppLaunchHook.files(root)
    File.write!(script, contents)

    {:ok, root: root, script: script}
  end

  test "settings run the script with perl before each Bash command", %{root: root, script: script} do
    assert %{"PreToolUse" => [%{"matcher" => "Bash", "hooks" => [hook]}]} = AppLaunchHook.settings(root)
    assert hook["type"] == "command"
    assert hook["command"] == "/usr/bin/perl '#{script}'"
    assert hook["timeout"] == 10

    assert %{"PreToolUse" => [%{"hooks" => [%{"command" => quoted}]}]} = AppLaunchHook.settings("/tmp/it's")
    assert quoted == ~S(/usr/bin/perl '/tmp/it'"'"'s/app-launch-hook.pl')
  end

  test "refuses a program that starts an app", %{root: root, script: script} do
    executable!(root, "probe", @macho <> "\0\0_OBJC_CLASS_$_NSApplication\0")
    executable!(root, "demo", @macho <> "_$s7SwiftUI3AppPAAE4mainyyFZ")
    executable!(root, "sub/alert", @macho <> "_OBJC_CLASS_$_NSAlert")

    for command <- [
          "./probe",
          "./probe crash",
          "#{root}/probe",
          "swiftc -O probe.swift -o probe && ./probe",
          "FOO=1 env BAR=2 timeout 10 ./demo",
          "cd sub && ./alert",
          "echo hi; ( ./demo & )"
        ] do
      assert {stderr, 2} = run(script, root, command), command
      assert stderr =~ "starts a macOS app"
    end
  end

  test "finds the app's names across a read boundary", %{root: root, script: script} do
    padding = :binary.copy("x", 1_048_576 - byte_size(@macho) - 10)
    executable!(root, "big", @macho <> padding <> "_OBJC_CLASS_$_NSWindow")

    assert {_stderr, 2} = run(script, root, "./big")
  end

  test "lets other programs and other uses of an app's file run", %{root: root, script: script} do
    executable!(root, "probe", @macho <> "_OBJC_CLASS_$_NSApplication")
    executable!(root, "render", @macho <> "_$s7SwiftUI13ImageRendererC")
    executable!(root, "script.sh", "#!/bin/sh\n# NSApplication\n")
    File.write!(Path.join(root, "plain"), @macho <> "_OBJC_CLASS_$_NSApplication")

    for command <- [
          "./render",
          "./script.sh",
          "./plain",
          "./missing",
          "otool -L ./probe",
          "codesign --verify ./probe",
          "mix test",
          "swift build",
          "swift test",
          "cd"
        ] do
      assert {"", 0} = run(script, root, command), command
    end
  end

  test "refuses swift run of an app product and a Swift script that starts one", %{root: root, script: script} do
    executable!(root, "pkg/.build/debug/App", @macho <> "_OBJC_CLASS_$_NSApplication")
    executable!(root, "pkg/.build/debug/Tool", @macho <> "_main")
    executable!(root, "scratch/release/App", @macho <> "_NSApplicationMain")
    File.write!(Path.join(root, "app.swift"), "import SwiftUI\n@main struct Demo: App {}\n")
    File.write!(Path.join(root, "tool.swift"), "print(1)\n")

    for command <- [
          "cd pkg && swift run",
          "swift run --package-path pkg App",
          "swift run --scratch-path scratch -c release",
          "swift -module-cache-path mc app.swift"
        ] do
      assert {_stderr, 2} = run(script, root, command), command
    end

    for command <- ["swift run --package-path pkg Tool", "swift tool.swift", "swift missing.swift", "swift run --package-path nowhere"] do
      assert {"", 0} = run(script, root, command), command
    end
  end

  test "refuses running what the same line builds from app sources", %{root: root, script: script} do
    File.write!(Path.join(root, "app.swift"), "import AppKit\nlet app = NSApplication.shared\n")
    File.write!(Path.join(root, "app.m"), "#import <AppKit/AppKit.h>\nint main() { [NSApplication sharedApplication]; }\n")
    File.mkdir_p!(Path.join(root, "pkg/Sources/Demo"))
    File.write!(Path.join(root, "pkg/Sources/Demo/main.swift"), "import SwiftUI\n@main struct Demo: App {}\n")

    for command <- [
          "swiftc -parse-as-library app.swift -o fresh && ./fresh",
          "clang -framework AppKit app.m -o fresh2 && ./fresh2",
          "xcrun --sdk macosx swiftc app.swift -o out/../fresh3; #{root}/fresh3",
          "swiftc app.swift && ./app",
          "cc app.m -framework AppKit && ./a.out",
          "cat > new.swift <<'EOF'\nimport AppKit\nNSApplication.shared.run()\nEOF\nswiftc new.swift -o new && ./new",
          "cat > new.swift <<'EOF'\nNSApplication.shared.run()\nEOF\nswift new.swift",
          "cd pkg && swift build && ./.build/debug/Demo",
          "swift build --package-path pkg -c release && pkg/.build/arm64-apple-macosx/release/Demo",
          "swift run --package-path pkg",
          "swift run --package-path pkg Demo"
        ] do
      refute File.exists?(Path.join(root, "fresh"))
      assert {stderr, 2} = run(script, root, command), command
      assert stderr =~ "starts a macOS app"
    end

    File.write!(Path.join(root, "tool.swift"), "print(1)\n")
    File.mkdir_p!(Path.join(root, "pkg/Sources/Tool"))
    File.write!(Path.join(root, "pkg/Sources/Tool/main.swift"), "print(1)\n")

    for command <- [
          "swiftc tool.swift -o tool && ./tool",
          "swiftc app.swift -o fresh && ./other",
          "swiftc -c app.swift",
          "swiftc missing.swift -o missing && ./missing",
          "cd pkg && swift build && ./.build/debug/Tool",
          "swift run --package-path pkg Tool",
          "xcrun"
        ] do
      assert {"", 0} = run(script, root, command), command
    end
  end

  test "lets through input that isn't a Bash command", %{root: root, script: script} do
    for input <- ["{bad", ~s({"tool_input": "x"}), ~s({"tool_input": {"command": ["./probe"]}})] do
      assert {"", 0} = hook(script, input)
    end

    executable!(root, "probe", @macho <> "_OBJC_CLASS_$_NSApplication")
    # Without a working directory the command runs where Claude Code runs it.
    assert {"", 0} = hook(script, Jason.encode!(%{tool_input: %{command: "./probe"}}))
  end

  defp executable!(root, name, contents) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp run(script, cwd, command) do
    hook(script, Jason.encode!(%{tool_name: "Bash", cwd: cwd, tool_input: %{command: command}}))
  end

  defp hook(script, input) do
    input_path = Path.join(Path.dirname(script), "input-#{System.unique_integer([:positive])}.json")
    File.write!(input_path, input)
    System.cmd("/bin/sh", ["-c", ~s(/usr/bin/perl "$0" < "$1" 2>&1 >/dev/null), script, input_path])
  end
end
