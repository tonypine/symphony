defmodule SymphonyElixir.QaDriver.GalleryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaDriver.{Gallery, Picture}

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
      assert Gallery.arguments(%{}) == {:ok, %{entry: nil, variation: nil, width: nil, appearance: nil}}

      assert Gallery.arguments(%{"entry" => "home", "variation" => "home-busy_2.x", "width" => "1100", "appearance" => "dark"}) ==
               {:ok, %{entry: "home", variation: "home-busy_2.x", width: "1100", appearance: "dark"}}

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
            %{"entry" => "home", "appearance" => "sepia"},
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

  describe "listing/2" do
    test "returns the entries and the widths", context do
      config = config(context, fn @gallery, ["--entries"] -> {:ok, {Jason.encode!(@entries), 0}} end)

      assert Gallery.listing(config, @gallery) == {:ok, %{"entries" => @entries["entries"], "widths" => @entries["widths"]}}

      assert_received {:cmd, @gallery, ["--entries"], opts}
      # The whole answer is kept, not the last few thousand bytes.
      assert opts[:output_limit] >= 1_000_000
    end

    test "fails when the gallery fails or answers something else", context do
      for {entries, expected} <- [
            {{:ok, {"dyld: Library not loaded\n", 6}}, "exit 6): dyld: Library not loaded"},
            {{:error, :timeout}, "could not run on the QA host: :timeout"},
            {{:ok, {"not json", 0}}, "answer to --entries could not be read: not json"},
            {{:ok, {~s({"entries":"none"}), 0}}, "answer to --entries"}
          ] do
        config = config(context, fn @gallery, ["--entries"] -> entries end)

        assert {"qa_gallery_failed", message} = failure(Gallery.listing(config, @gallery))
        assert message =~ expected
      end
    end
  end

  # A QA host that runs the shell for real, here, and draws `pictures` (a file name to its PNG) for each gallery.
  defp drawing_host(context, pictures_by_gallery, grep \\ fn _gallery -> {:ok, {"", 0}} end) do
    config(context, fn
      "/usr/bin/grep", ["-q", "-a", "-F", "--", "--shot-all", gallery] ->
        grep.(gallery)

      "/bin/sh", args ->
        {:ok, System.cmd("/bin/sh", args)}

      gallery, ["--shot-all", "--width", _width, "--appearance", _appearance, "--out", out] ->
        File.mkdir_p!(out)

        for {name, png} <- Map.fetch!(pictures_by_gallery, gallery), do: File.write!(Path.join(out, name), png)

        {:ok, {"sysctlbyname failed\n" <> Enum.map_join(Map.fetch!(pictures_by_gallery, gallery), "", fn {name, _png} -> Path.join(out, name) <> "\n" end), 0}}
    end)
  end

  defp png(colour, scale \\ 2, size \\ 2), do: Picture.encode(size, size, :binary.copy(colour, size * size), scale)

  describe "draw_all/4" do
    test "draws every entry in one run, at the target, into a folder of its own", context do
      config = drawing_host(context, %{@gallery => [{"button-1-dark.png", png(<<0, 0, 0, 255>>)}, {"home-busy-desktop-dark.png", png(<<1, 1, 1, 255>>)}]})

      assert {:ok, %{dir: dir, pictures: ["button-1-dark.png", "home-busy-desktop-dark.png"]}} =
               Gallery.draw_all(config, @gallery, %{width: "2560", appearance: "dark"}, "change")

      assert Path.dirname(dir) == context.host_dir
      assert Path.basename(dir) =~ ~r/^gallery-change-\d+$/
      assert_received {:cmd, "/usr/bin/grep", ["-q", "-a", "-F", "--", "--shot-all", @gallery], _opts}
      assert_received {:cmd, @gallery, ["--shot-all", "--width", "2560", "--appearance", "dark", "--out", ^dir], opts}
      assert opts[:timeout_ms] >= 600_000
    end

    test "refuses a gallery from before --shot-all, before it opens a window", context do
      config = drawing_host(context, %{}, fn _gallery -> {:ok, {"", 1}} end)

      assert {"qa_gallery_too_old", message} = failure(Gallery.draw_all(config, @gallery, %{width: "2560", appearance: "dark"}, "base"))
      assert message =~ "The base's Component Gallery was built before it drew every entry in one run"
      refute_received {:cmd, @gallery, _args, _opts}

      unreachable = drawing_host(context, %{}, fn _gallery -> {:error, :closed} end)
      assert {"qa_gallery_failed", message} = failure(Gallery.draw_all(unreachable, @gallery, %{width: "2560", appearance: "dark"}, "base"))
      assert message =~ "could not be asked about the base's Component Gallery: :closed"
    end

    test "fails when the gallery fails or draws nothing", context do
      host = drawing_host(context, %{@gallery => []})
      target = %{width: "1440", appearance: "light"}
      assert {"qa_gallery_failed", message} = failure(Gallery.draw_all(host, @gallery, target, "change"))
      assert message =~ "drew no picture"

      failing =
        config(context, fn
          "/usr/bin/grep", _args -> {:ok, {"", 0}}
          @gallery, _args -> {:ok, {"Fatal error: Could not draw home-busy", 134}}
        end)

      assert {"qa_gallery_failed", message} = failure(Gallery.draw_all(failing, @gallery, %{width: "1440", appearance: "light"}, "change"))
      assert message =~ "exit 134): Fatal error: Could not draw home-busy"
    end
  end

  describe "compare/3" do
    # The change's gallery and its base's, drawn into folders of their own.
    defp drawn(context, head, base) do
      config = drawing_host(context, %{"head" => head, "base" => base})
      target = %{width: "2560", appearance: "dark"}
      {:ok, head} = Gallery.draw_all(config, "head", target, "change")
      {:ok, base} = Gallery.draw_all(config, "base", target, "base")
      {config, head, base}
    end

    test "judges the pictures whose pixels differ and the new ones, never the same or the removed", context do
      black = png(<<0, 0, 0, 255>>)
      grey = png(<<9, 9, 9, 255>>)

      {config, head, base} =
        drawn(
          context,
          [{"same-1-dark.png", black}, {"changed-1-dark.png", grey}, {"new-1-dark.png", black}, {"rescaled-1-dark.png", png(<<0, 0, 0, 255>>, 1)}, {"resized-1-dark.png", png(<<0, 0, 0, 255>>, 2, 3)}],
          [{"same-1-dark.png", black}, {"changed-1-dark.png", black}, {"removed-1-dark.png", black}, {"rescaled-1-dark.png", black}, {"resized-1-dark.png", black}]
        )

      assert Gallery.compare(config, head, base) ==
               {:ok,
                %{
                  changed: ["changed-1-dark.png", "resized-1-dark.png"],
                  new: ["new-1-dark.png"],
                  removed: ["removed-1-dark.png"],
                  # Written again with another `pHYs` but the same pixels: the same picture.
                  same: ["same-1-dark.png", "rescaled-1-dark.png"],
                  # The QA host removes a file it reads: the change's pictures that differ are kept.
                  pngs: %{"changed-1-dark.png" => grey, "resized-1-dark.png" => png(<<0, 0, 0, 255>>, 2, 3)}
                }}
    end

    test "decodes only the pairs whose bytes differ", context do
      black = png(<<0, 0, 0, 255>>)
      {config, head, base} = drawn(context, [{"same-1-dark.png", black}], [{"same-1-dark.png", black}])
      config = %{config | host: %{config.host | read: fn path -> flunk("read #{path}") end}}

      assert {:ok, %{changed: [], new: [], removed: [], same: ["same-1-dark.png"]}} = Gallery.compare(config, head, base)
    end

    test "asks the QA host nothing when no picture is in both", context do
      config = config(context, fn executable, args -> flunk("ran #{executable} #{inspect(args)}") end)

      assert Gallery.compare(config, %{dir: "/h", pictures: ["a.png"]}, %{dir: "/b", pictures: ["b.png"]}) ==
               {:ok, %{changed: [], new: ["a.png"], removed: ["b.png"], same: [], pngs: %{}}}
    end

    test "fails, naming the picture, when one cannot be read or compared", context do
      {config, head, base} = drawn(context, [{"a-1-dark.png", "not a png"}], [{"a-1-dark.png", png(<<0, 0, 0, 255>>)}])
      assert {"qa_gallery_failed", message} = failure(Gallery.compare(config, head, base))
      assert message == "The picture a-1-dark.png could not be compared: it is not a PNG."

      {config, head, base} = drawn(context, [{"b-1-dark.png", png(<<1, 0, 0, 255>>)}], [{"b-1-dark.png", png(<<0, 0, 0, 255>>)}])
      unreadable = %{config | host: %{config.host | read: fn _path -> {:error, :enoent} end}}
      assert {"qa_gallery_failed", message} = failure(Gallery.compare(unreadable, head, base))
      assert message =~ "The picture b-1-dark.png could not be copied from the QA host: :enoent"

      failing = %{config | host: %{config.host | cmd: fn _executable, _args, _opts -> {:ok, {"cmp: not found", 127}} end}}
      assert {"qa_gallery_failed", message} = failure(Gallery.compare(failing, head, base))
      assert message =~ "exit 127): cmp: not found"
    end
  end

  describe "save/3" do
    test "copies the named pictures into qa-evidence/ under their own names", context do
      black = png(<<0, 0, 0, 255>>)
      config = drawing_host(context, %{@gallery => [{"a-1-dark.png", black}, {"b-1-dark.png", black}]})
      {:ok, drawn} = Gallery.draw_all(config, @gallery, %{width: "2560", appearance: "dark"}, "change")

      assert Gallery.save(config, drawn, ["b-1-dark.png"]) == {:ok, %{"files" => [%{"path" => "qa-evidence/b-1-dark.png"}]}}
      assert File.read!(Path.join(context.worktree, "qa-evidence/b-1-dark.png")) == black
      refute File.exists?(Path.join(context.worktree, "qa-evidence/a-1-dark.png"))

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/b-1-dark.png", "existing" => true}]}} = Gallery.save(config, drawn, ["b-1-dark.png"])
      assert Gallery.save(config, drawn, []) == {:ok, %{"files" => []}}

      # A picture the comparison read already is saved from what it read: the QA host removed the file.
      gone = %{config | host: %{config.host | read: fn _path -> {:error, :enoent} end}}
      assert Gallery.save(gone, drawn, ["a-1-dark.png"], %{"a-1-dark.png" => black}) == {:ok, %{"files" => [%{"path" => "qa-evidence/a-1-dark.png"}]}}
      assert {"qa_gallery_failed", message} = failure(Gallery.save(gone, drawn, ["c-1-dark.png"], %{"a-1-dark.png" => black}))
      assert message =~ "c-1-dark.png could not be copied from the QA host: :enoent"
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

      # One appearance alone when the call names it.
      dark = config(context, entries_then(&draw(&1, ["button-1-dark.png"])))

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/button-1-dark.png"}]}} =
               Gallery.shoot(dark, @gallery, %{entry: "button", variation: nil, width: nil, appearance: "dark"})

      assert_received {:cmd, @gallery, ["--shot", "button", "--appearance", "dark", "--out", _out], _opts}

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

      assert {:ok, %{"files" => [_light, _dark]} = first} = Gallery.shoot(config(context, shot), @gallery, arguments)
      refute Map.has_key?(first, "note")
      light = Path.join(context.worktree, "qa-evidence/button-1-light.png")
      File.write!(light, "the first drawing")

      # A picture this pass drew before comes back with its path, kept as it was; no refusal.
      assert {:ok, %{"files" => files, "note" => note}} = Gallery.shoot(config(context, shot), @gallery, arguments)

      assert files == [
               %{"path" => "qa-evidence/button-1-light.png", "existing" => true},
               %{"path" => "qa-evidence/button-1-dark.png", "existing" => true}
             ]

      assert note =~ "is the picture this pass drew before under that name"
      assert File.read!(light) == "the first drawing"

      # One new picture beside one drawn before: only the earlier one is marked.
      File.rm!(Path.join(context.worktree, "qa-evidence/button-1-dark.png"))

      assert {:ok, %{"files" => [%{"existing" => true}, %{"path" => "qa-evidence/button-1-dark.png"} = dark]}} =
               Gallery.shoot(config(context, shot), @gallery, arguments)

      refute Map.has_key?(dark, "existing")

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
