defmodule SymphonyElixir.AgentCachesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentCaches

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-caches-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    config = %{
      root: Path.join([test_root, "cache", "agent"]),
      host_hex_home: Path.join(test_root, "host-hex"),
      host_elixir_make_cache: Path.join(test_root, "host-elixir-make")
    }

    %{test_root: test_root, config: config}
  end

  test "points Hex, elixir_make and the repo's tools at the folder", %{config: config} do
    root = config.root

    assert AgentCaches.env(config) == %{
             "HEX_HOME" => Path.join(root, "hex"),
             "ELIXIR_MAKE_CACHE_DIR" => Path.join(root, "elixir_make"),
             "SYMPHONY_AGENT_CACHE_DIR" => root
           }

    assert AgentCaches.write_paths(config) == [canonical(root)]
    assert File.dir?(Path.join(root, "hex"))
    assert File.dir?(Path.join(root, "elixir_make"))
  end

  test "copies what the host caches hold that the folder lacks", %{config: config} do
    host_hexpm = Path.join([config.host_hex_home, "packages", "hexpm"])
    host_org = Path.join([config.host_hex_home, "packages", "hexpm:acme"])
    File.mkdir_p!(host_hexpm)
    File.mkdir_p!(host_org)
    File.mkdir_p!(config.host_elixir_make_cache)
    File.write!(Path.join(host_hexpm, "jason-1.4.5.tar"), "jason")
    File.write!(Path.join(host_org, "secret_sauce-0.1.0.tar"), "sauce")
    File.write!(Path.join(config.host_hex_home, "cache.ets"), "registry")
    File.write!(Path.join(config.host_hex_home, "hex.config"), "api_key")
    File.write!(Path.join(config.host_elixir_make_cache, "lazy_html-nif.tar.gz"), "nif")

    hex_home = Path.join(config.root, "hex")
    kept = Path.join([hex_home, "packages", "hexpm", "jason-1.4.5.tar"])
    File.mkdir_p!(Path.dirname(kept))
    File.write!(kept, "already here")

    assert %{"HEX_HOME" => ^hex_home} = AgentCaches.env(config)

    assert File.read!(kept) == "already here"
    assert File.read!(Path.join([hex_home, "packages", "hexpm:acme", "secret_sauce-0.1.0.tar"])) == "sauce"
    assert File.read!(Path.join(hex_home, "cache.ets")) == "registry"
    refute File.exists?(Path.join(hex_home, "hex.config"))
    assert File.read!(Path.join([config.root, "elixir_make", "lazy_html-nif.tar.gz"])) == "nif"
    assert Enum.sort(File.ls!(Path.join([hex_home, "packages", "hexpm"]))) == ["jason-1.4.5.tar"]

    # The host caches are only read.
    assert File.read!(Path.join(host_hexpm, "jason-1.4.5.tar")) == "jason"
  end

  test "never writes through links in the folder", %{test_root: test_root, config: config} do
    outside = Path.join(test_root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "cache.ets"), "keep")

    File.mkdir_p!(Path.join([config.host_hex_home, "packages", "hexpm"]))
    File.write!(Path.join([config.host_hex_home, "packages", "hexpm", "jason-1.4.5.tar"]), "jason")
    File.write!(Path.join(config.host_hex_home, "cache.ets"), "registry")
    File.mkdir_p!(config.host_elixir_make_cache)
    File.write!(Path.join(config.host_elixir_make_cache, "nif.tar.gz"), "nif")

    # Links inside the Hex home, and an `elixir_make` folder that is a link.
    hex_home = Path.join(config.root, "hex")
    File.mkdir_p!(hex_home)
    File.ln_s!(outside, Path.join(hex_home, "packages"))
    File.ln_s!(Path.join(outside, "cache.ets"), Path.join(hex_home, "cache.ets"))
    File.ln_s!(outside, Path.join(config.root, "elixir_make"))

    assert %{"HEX_HOME" => ^hex_home} = AgentCaches.env(config)
    assert File.ls!(outside) == ["cache.ets"]
    assert File.read!(Path.join(outside, "cache.ets")) == "keep"

    # A Hex home that is a link.
    File.rm_rf!(hex_home)
    File.ln_s!(outside, hex_home)

    assert %{"HEX_HOME" => ^hex_home} = AgentCaches.env(config)
    assert File.ls!(outside) == ["cache.ets"]
  end

  test "only copies regular files", %{test_root: test_root, config: config} do
    File.mkdir_p!(config.host_elixir_make_cache)
    File.mkdir_p!(Path.join(config.host_elixir_make_cache, "nested"))
    File.write!(Path.join(test_root, "elsewhere.tar.gz"), "elsewhere")
    File.ln_s!(Path.join(test_root, "elsewhere.tar.gz"), Path.join(config.host_elixir_make_cache, "linked.tar.gz"))

    unreadable = Path.join(config.host_elixir_make_cache, "unreadable.tar.gz")
    File.write!(unreadable, "secret")
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod(unreadable, 0o600) end)

    assert %{} = AgentCaches.env(config)
    assert File.ls!(Path.join(config.root, "elixir_make")) == []
  end

  test "gives no env or write access when the folder is not a plain directory", %{test_root: test_root, config: config} do
    outside = Path.join(test_root, "outside")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.dirname(config.root))
    File.ln_s!(outside, config.root)

    assert AgentCaches.env(config) == %{}
    assert AgentCaches.write_paths(config) == []
    assert File.ls!(outside) == []
  end

  test "reads its folder and the host caches from the app env, else the host" do
    overrides = Application.get_env(:symphony_elixir, :agent_caches)

    assert AgentCaches.config() == Map.new(overrides)
    assert AgentCaches.write_paths() == [canonical(overrides[:root])]
    assert %{"SYMPHONY_AGENT_CACHE_DIR" => root} = AgentCaches.env()
    assert root == overrides[:root]

    assert AgentCaches.config([], %{"HEX_HOME" => "~/hex-home", "ELIXIR_MAKE_CACHE_DIR" => "/caches/elixir_make"}) == %{
             root: Path.join(:filename.basedir(:user_cache, "symphony"), "agent"),
             host_hex_home: Path.expand("~/hex-home"),
             host_elixir_make_cache: "/caches/elixir_make"
           }

    assert %{host_hex_home: hex_home, host_elixir_make_cache: elixir_make_cache} =
             AgentCaches.config([], %{"HEX_HOME" => "", "ELIXIR_MAKE_CACHE_DIR" => ""})

    assert hex_home == Path.join(System.user_home!(), ".hex")
    assert elixir_make_cache == :filename.basedir(:user_cache, "elixir_make")
  end

  defp canonical(path) do
    {:ok, canonical_path} = SymphonyElixir.PathSafety.canonicalize(path)
    canonical_path
  end
end
