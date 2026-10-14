defmodule SymphonyElixir.ReleasePackageScriptTest do
  use ExUnit.Case, async: true

  @package_script Path.expand("../../scripts/release/package.sh", __DIR__)
  @repo_root Path.expand("../..", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "symphony-release-package-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  test "the release notes' install line names macOS 26 as the minimum", %{tmp: tmp} do
    app = Path.join(tmp, "Symphony.app")
    File.mkdir_p!(Path.join(app, "Contents/Resources"))
    write_executable!(Path.join(app, "Contents/Resources/symphony"), "#!/bin/sh\n")

    # `ditto` is macOS-only; a stub that writes the zip keeps the test running on Linux CI.
    bin = Path.join(tmp, "bin")
    write_executable!(Path.join(bin, "ditto"), ~s(#!/bin/sh\nfor last; do :; done\nprintf 'zip' > "$last"\n))

    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: @repo_root)
    out = Path.join(tmp, "dist")

    args = [
      @package_script,
      "--app",
      app,
      "--version",
      "0.0.1.42",
      "--build",
      "42",
      "--commit",
      String.trim(commit),
      "--tag",
      "v0.0.1.42",
      "--signed",
      "false",
      "--out",
      out
    ]

    env = [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"MINISIGN_SECRET_KEY", nil}]

    assert {_output, 0} = System.cmd("sh", args, cd: @repo_root, env: env, stderr_to_stdout: true)

    notes = File.read!(Path.join(out, "release_notes.md"))
    assert notes =~ "Symphony.app runs on Apple silicon Macs with macOS 26 or later."
  end

  defp write_executable!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
