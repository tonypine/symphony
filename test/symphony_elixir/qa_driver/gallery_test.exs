defmodule SymphonyElixir.QaDriver.GalleryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaDriver.Gallery

  @gallery "/run/builds/1/Symphony.app/Contents/Helpers/SymphonyGallery"
  @entries %{
    "entries" => [
      %{"id" => "button", "kind" => "component", "variations" => ["button-primary"]},
      %{"id" => "home", "kind" => "screen", "variations" => ["home-empty", "home-busy"]}
    ],
    "widths" => %{"laptop" => 1440, "desktop" => 2560},
    "foundation" => ["Tokens.swift"]
  }

  setup do
    root = Path.join(System.tmp_dir!(), "qa-gallery-test-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "worktree")
    host_dir = Path.join(root, "run")
    File.mkdir_p!(worktree)
    File.mkdir_p!(host_dir)
    on_exit(fn -> File.rm_rf(root) end)
    %{worktree: worktree, host_dir: host_dir}
  end

  # A QA host whose commands answer from `cmd` and tell the test what ran; `read` reads this machine's files.
  defp config(context, cmd, read \\ &File.read/1) do
    test = self()

    host = %{
      cmd: fn executable, args, opts ->
        send(test, {:cmd, executable, args, opts})
        cmd.(executable, args)
      end,
      read: read
    }

    %{host: host, host_dir: context.host_dir, worktree: context.worktree}
  end

  defp entries_then(shot) do
    fn
      @gallery, ["--entries"] -> {:ok, {Jason.encode!(@entries), 0}}
      @gallery, ["--shot" | _rest] = args -> shot.(List.last(args))
    end
  end

  defp draw(out, names) do
    File.mkdir_p!(out)
    for name <- names, do: File.write!(Path.join(out, name), "png " <> name)
    {:ok, {Enum.map_join(names, &(Path.join(out, &1) <> "\n")), 0}}
  end

  defp failure({:error, {:qa_tool, code, message}}), do: {code, message}

  test "names the gallery's fixtures and its place in the bundle" do
    assert Gallery.fixtures() == "macos/Tests/Fixtures/gallery"
    assert Gallery.path("/run/builds/1/Symphony.app/Contents/MacOS/Symphony") == @gallery
  end

  describe "arguments/1" do
    test "takes names and a width" do
      assert Gallery.arguments(%{}) == {:ok, %{entry: nil, variation: nil, width: nil}}

      assert Gallery.arguments(%{"entry" => "home", "variation" => "home-busy_2.x", "width" => "1100"}) ==
               {:ok, %{entry: "home", variation: "home-busy_2.x", width: "1100"}}

      for width <- ~w(laptop desktop 800 25600) do
        assert {:ok, %{width: ^width}} = Gallery.arguments(%{"entry" => "home", "width" => width})
      end
    end

    test "refuses anything else" do
      long = String.duplicate("a", 121)

      for args <- [
            %{"entry" => ""},
            %{"entry" => "a/b"},
            %{"entry" => "button\n"},
            %{"entry" => long},
            %{"entry" => 7},
            %{"entry" => "home", "variation" => "a b"},
            %{"entry" => "home", "variation" => ["home-busy"]},
            %{"entry" => "home", "width" => "wide"},
            %{"entry" => "home", "width" => "99"},
            %{"entry" => "home", "width" => "123456"},
            %{"entry" => "home", "width" => 1440},
            %{"variation" => "home-busy"},
            %{"width" => "laptop"}
          ] do
        assert {"invalid_arguments", _message} = failure(Gallery.arguments(args))
      end

      assert {:ok, %{entry: entry}} = Gallery.arguments(%{"entry" => String.duplicate("a", 120)})
      assert byte_size(entry) == 120
    end
  end

  describe "open/1" do
    test "returns the launch's arguments and the app's" do
      assert Gallery.open(%{"entry" => "button"}) ==
               {:ok, %{"api_fixtures" => "macos/Tests/Fixtures/gallery", "environment" => "fixture", "appearance" => nil}, ["--open", "button"]}

      assert {:ok, %{"appearance" => "dark"}, ["--open", "home", "--variation", "home-busy", "--width", "laptop", "--dark"]} =
               Gallery.open(%{"entry" => "home", "variation" => "home-busy", "width" => "laptop", "appearance" => "dark"})

      assert {:ok, %{"appearance" => "light"}, ["--open", "home", "--width", "1100"]} = Gallery.open(%{"entry" => "home", "width" => "1100", "appearance" => "light"})
    end

    test "needs an entry and a known appearance" do
      assert {"invalid_arguments", message} = failure(Gallery.open(%{}))
      assert message =~ "`entry` is required"
      assert {"invalid_arguments", _message} = failure(Gallery.open(%{"entry" => "a b"}))
      assert {"invalid_arguments", message} = failure(Gallery.open(%{"entry" => "home", "appearance" => "sepia"}))
      assert message =~ "`appearance`"
    end
  end

  describe "ensure_present/2" do
    test "asks the QA host for the executable", context do
      assert Gallery.ensure_present(config(context, fn "/bin/test", ["-x", @gallery] -> {:ok, {"", 0}} end), @gallery) == :ok

      absent = config(context, fn _test, _args -> {:ok, {"", 1}} end)
      assert {"qa_gallery_missing", message} = failure(Gallery.ensure_present(absent, @gallery))
      assert message =~ "carries no Component Gallery at Contents/Helpers/SymphonyGallery"

      unreachable = config(context, fn _test, _args -> {:error, :timeout} end)
      assert {"qa_gallery_failed", message} = failure(Gallery.ensure_present(unreachable, @gallery))
      assert message =~ ":timeout"
    end
  end

  describe "listing/3" do
    test "returns the entries, the widths and the affected entries", context do
      changed = ["macos/Sources/SymphonyBarUI/Button.swift", "docs/a file.md"]

      config =
        config(context, fn
          @gallery, ["--entries"] -> {:ok, {Jason.encode!(@entries), 0}}
          "/bin/sh", ["-c", _script, "sh", @gallery | ^changed] -> {:ok, {~s({"all":false,"entries":["button"]}\n), 0}}
        end)

      assert Gallery.listing(config, @gallery, {:ok, changed}) ==
               {:ok, %{"entries" => @entries["entries"], "widths" => @entries["widths"], "affected" => %{"all" => false, "entries" => ["button"]}}}

      assert_received {:cmd, "/bin/sh", ["-c", script | _rest], opts}
      assert script == ~s(g=$1; shift; printf '%s\\n' "$@" | "$g" --affected)
      # The whole answer is kept, not the last few thousand bytes.
      assert opts[:output_limit] >= 1_000_000
    end

    test "the shell hands the gallery one path a line", context do
      gallery = Path.join(context.host_dir, "gallery")
      File.write!(gallery, "#!/bin/sh\nprintf '{\"all\":true,\"entries\":['; sed 's/.*/\"&\"/' | paste -sd, - | tr -d '\\n'; printf ']}'\n")
      File.chmod!(gallery, 0o755)

      config =
        config(context, fn
          ^gallery, ["--entries"] -> {:ok, {Jason.encode!(@entries), 0}}
          "/bin/sh", args -> {:ok, System.cmd("/bin/sh", args)}
        end)

      assert {:ok, %{"affected" => %{"all" => true, "entries" => ["a b.swift", "$HOME/c.swift"]}}} = Gallery.listing(config, gallery, {:ok, ["a b.swift", "$HOME/c.swift"]})
    end

    test "runs nothing for a PR that changes no file", context do
      config = config(context, fn @gallery, ["--entries"] -> {:ok, {Jason.encode!(@entries), 0}} end)
      assert {:ok, %{"affected" => %{"all" => false, "entries" => []}} = payload} = Gallery.listing(config, @gallery, {:ok, []})
      refute Map.has_key?(payload, "note")
    end

    test "says why `affected` is unknown when the changed files could not be listed", context do
      config = config(context, fn @gallery, ["--entries"] -> {:ok, {Jason.encode!(@entries), 0}} end)
      unlisted = {:error, {:git_failed, 128, "fatal: bad object"}}
      assert {:ok, %{"entries" => [_button, _home], "affected" => nil, "note" => note}} = Gallery.listing(config, @gallery, unlisted)
      assert note =~ "could not be listed"
      assert note =~ "fatal: bad object"
    end

    test "fails when the gallery fails or answers something else", context do
      for {entries, affected, expected} <- [
            {{:ok, {"dyld: Library not loaded\n", 6}}, nil, "exit 6): dyld: Library not loaded"},
            {{:error, :timeout}, nil, "could not run on the QA host: :timeout"},
            {{:ok, {"not json", 0}}, nil, "answer to --entries could not be read: not json"},
            {{:ok, {~s({"entries":"none"}), 0}}, nil, "answer to --entries"},
            {{:ok, {Jason.encode!(@entries), 0}}, {:ok, {"boom", 1}}, "exit 1): boom"},
            {{:ok, {Jason.encode!(@entries), 0}}, {:ok, {~s({"all":"yes","entries":[]}), 0}}, "answer to --affected"}
          ] do
        config =
          config(context, fn
            @gallery, ["--entries"] -> entries
            "/bin/sh", _args -> affected
          end)

        assert {"qa_gallery_failed", message} = failure(Gallery.listing(config, @gallery, {:ok, ["a.swift"]}))
        assert message =~ expected
      end
    end
  end

  describe "shoot/3" do
    test "saves each picture the gallery prints, under its own name", context do
      names = ["home-busy-laptop-light.png", "home-busy-laptop-dark.png"]

      config =
        config(
          context,
          entries_then(fn out ->
            {:ok, {output, 0}} = draw(out, names)
            # A line that is not a picture in the folder is not fetched.
            {:ok, {"warning: something on stderr\n/etc/passwd.png\n" <> output <> output, 0}}
          end)
        )

      assert Gallery.shoot(config, @gallery, %{entry: "home", variation: "home-busy", width: "laptop"}) ==
               {:ok, %{"files" => [%{"path" => "qa-evidence/home-busy-laptop-light.png"}, %{"path" => "qa-evidence/home-busy-laptop-dark.png"}]}}

      assert File.read!(Path.join(context.worktree, "qa-evidence/home-busy-laptop-dark.png")) == "png home-busy-laptop-dark.png"
      assert_received {:cmd, @gallery, ["--shot", "home", "--variation", "home-busy", "--width", "laptop", "--out", out], opts}
      assert Path.dirname(out) == context.host_dir
      assert opts[:timeout_ms] >= 60_000

      # Each call draws into a folder of its own.
      File.rm_rf!(Path.join(context.worktree, "qa-evidence"))
      assert {:ok, _files} = Gallery.shoot(config, @gallery, %{entry: "home", variation: "home-busy", width: "laptop"})
      assert_received {:cmd, @gallery, ["--shot" | rest], _opts}
      refute List.last(rest) == out
    end

    test "draws a component whole, and a screen only by variation", context do
      config = config(context, entries_then(&draw(&1, ["button-1-light.png"])))
      assert {:ok, %{"files" => [%{"path" => "qa-evidence/button-1-light.png"}]}} = Gallery.shoot(config, @gallery, %{entry: "button", variation: nil, width: nil})
      assert_received {:cmd, @gallery, ["--shot", "button", "--out", _out], _opts}

      assert {"invalid_arguments", message} = failure(Gallery.shoot(config, @gallery, %{entry: "home", variation: nil, width: "laptop"}))
      assert message == "home is a screen: pass `variation`, one of home-empty, home-busy."
      refute_received {:cmd, @gallery, ["--shot", "home" | _rest], _opts}
    end

    test "leaves an entry the list does not have to the gallery", context do
      config = config(context, entries_then(fn _out -> {:ok, {"No entry is named ghost. The entries: button, home\n", 2}} end))
      assert {"qa_gallery_failed", message} = failure(Gallery.shoot(config, @gallery, %{entry: "ghost", variation: nil, width: nil}))
      assert message == "The Component Gallery failed (exit 2): No entry is named ghost. The entries: button, home"
    end

    test "keeps the tail of a long failure", context do
      config = config(context, entries_then(fn _out -> {:ok, {String.duplicate("x", 3_000) <> "the end", 1}} end))
      assert {"qa_gallery_failed", message} = failure(Gallery.shoot(config, @gallery, %{entry: "button", variation: nil, width: nil}))
      assert message =~ "(exit 1): …x"
      assert String.ends_with?(message, "the end")
    end

    test "fails when the list cannot be read or nothing was drawn", context do
      config = config(context, fn @gallery, ["--entries"] -> {:ok, {"", 1}} end)
      assert {"qa_gallery_failed", _message} = failure(Gallery.shoot(config, @gallery, %{entry: "button", variation: nil, width: nil}))

      config = config(context, entries_then(fn _out -> {:ok, {"nothing to draw\n", 0}} end))
      assert {"qa_gallery_failed", message} = failure(Gallery.shoot(config, @gallery, %{entry: "button", variation: nil, width: nil}))
      assert message =~ "drew no picture: nothing to draw"
    end

    test "fails when a picture cannot be copied or saved", context do
      shot = entries_then(&draw(&1, ["button-1-light.png", "button-1-dark.png"]))
      arguments = %{entry: "button", variation: nil, width: nil}

      assert {"qa_gallery_failed", message} = failure(Gallery.shoot(config(context, shot, fn _path -> {:error, :unreadable} end), @gallery, arguments))
      assert message =~ "button-1-light.png could not be copied from the QA host: :unreadable"

      assert {:ok, %{"files" => [_light, _dark]}} = Gallery.shoot(config(context, shot), @gallery, arguments)
      assert {"qa_screenshot_exists", message} = failure(Gallery.shoot(config(context, shot), @gallery, arguments))
      assert message =~ "qa-evidence/button-1-light.png already exists: this pass drew that picture before"

      # Another failure to save keeps its own words.
      evidence = Path.join(context.worktree, "qa-evidence")
      File.rm_rf!(evidence)
      File.mkdir_p!(evidence)
      File.chmod!(evidence, 0o500)
      on_exit(fn -> File.chmod(evidence, 0o700) end)
      assert {"qa_screenshot_failed", _message} = failure(Gallery.shoot(config(context, shot), @gallery, arguments))

      File.chmod!(evidence, 0o700)
      File.rm_rf!(evidence)
      File.write!(evidence, "a file")
      assert {"qa_evidence_unsafe", _message} = failure(Gallery.shoot(config(context, shot), @gallery, arguments))
    end
  end
end
