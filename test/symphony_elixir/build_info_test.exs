defmodule SymphonyElixir.BuildInfoTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.BuildInfo

  setup do
    previous = Application.fetch_env(:symphony_elixir, :build)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :build, value)
        :error -> Application.delete_env(:symphony_elixir, :build)
      end
    end)
  end

  test "a released build reports its version with the build number, its commit and its repository" do
    Application.put_env(:symphony_elixir, :build,
      sha: " D3D301B0123456789ABCDEF0123456789ABCDEF0 ",
      repo: "https://github.com/acme/symphony",
      number: "168"
    )

    assert BuildInfo.current() == %{
             version: "0.0.1.168",
             sha: "d3d301b0123456789abcdef0123456789abcdef0",
             repo: "https://github.com/acme/symphony"
           }
  end

  test "a build from a checkout has no build number, commit or repository" do
    Application.put_env(:symphony_elixir, :build, sha: nil, repo: " ", number: "")
    assert BuildInfo.current() == %{version: "0.0.1", sha: nil, repo: nil}

    Application.delete_env(:symphony_elixir, :build)
    assert BuildInfo.current() == %{version: "0.0.1", sha: nil, repo: nil}
  end

  test "a sha that isn't hex is ignored" do
    Application.put_env(:symphony_elixir, :build, sha: "main", repo: "https://github.com/acme/symphony", number: nil)
    assert %{sha: nil} = BuildInfo.current()
  end

  test "short_sha abbreviates like Git" do
    assert BuildInfo.short_sha("d3d301b0123456789abcdef") == "d3d301b"
  end
end
