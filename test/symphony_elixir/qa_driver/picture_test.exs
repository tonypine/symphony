defmodule SymphonyElixir.QaDriver.PictureTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias SymphonyElixir.QaDriver.{Checks, Picture}

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @white <<255, 255, 255, 255>>
  @black <<0, 0, 0, 255>>

  setup do
    worktree = Path.join(System.tmp_dir!(), "qa-picture-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(worktree, "qa-evidence"))
    on_exit(fn -> File.rm_rf(worktree) end)
    %{worktree: worktree}
  end

  # -- pictures the tests write ---------------------------------------------------------

  # RGBA rows of a white picture with black rectangles, each `{x, y, w, h}` in pixels.
  defp drawing(width, height, boxes) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>>, do: if(Enum.any?(boxes, &inside?(&1, x, y)), do: @black, else: @white)
  end

  defp inside?({bx, by, bw, bh}, x, y), do: x >= bx and x < bx + bw and y >= by and y < by + bh

  defp save!(worktree, name, png) do
    File.write!(Path.join([worktree, "qa-evidence", name]), png)
    "qa-evidence/" <> name
  end

  # A PNG as another encoder writes it: any colour type and depth, the rows filtered with
  # `filters` (one type per row, cycled), and extra chunks.
  defp png(width, height, color, depth, data, opts \\ []) do
    channels = Map.get(%{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}, color, 1)
    bpp = max(div(channels * depth, 8), 1)
    stride = div(width * channels * depth, 8)
    filters = Keyword.get(opts, :filters, [0])
    rows = if stride == 0, do: [], else: for(<<row::binary-size(stride) <- data>>, do: row)

    {raw, _prev} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], :binary.copy(<<0>>, stride)}, fn {row, index}, {acc, prev} ->
        type = Enum.at(filters, rem(index, length(filters)))
        {[acc, <<type>>, filter(type, row, prev, bpp)], row}
      end)

    ihdr = <<width::32, height::32, depth, color, 0, 0, Keyword.get(opts, :interlace, 0)>>
    chunks = [{"IHDR", ihdr} | Keyword.get(opts, :before, [])] ++ [{"IDAT", Keyword.get(opts, :idat, :zlib.compress(IO.iodata_to_binary(raw)))}, {"IEND", ""}]
    IO.iodata_to_binary([@signature | Enum.map(chunks, fn {type, body} -> chunk(type, body) end)])
  end

  defp chunk(type, body), do: [<<byte_size(body)::32>>, type, body, <<:erlang.crc32([type, body])::32>>]

  defp filter(0, row, _prev, _bpp), do: row

  defp filter(type, row, prev, bpp) do
    for index <- 0..(byte_size(row) - 1), into: <<>> do
      left = if index >= bpp, do: :binary.at(row, index - bpp), else: 0
      up_left = if index >= bpp, do: :binary.at(prev, index - bpp), else: 0
      <<band(:binary.at(row, index) - predict(type, left, :binary.at(prev, index), up_left), 255)>>
    end
  end

  defp predict(1, left, _up, _up_left), do: left
  defp predict(2, _left, up, _up_left), do: up
  defp predict(3, left, up, _up_left), do: div(left + up, 2)

  defp predict(4, left, up, up_left) do
    estimate = left + up - up_left
    {a, b, c} = {abs(estimate - left), abs(estimate - up), abs(estimate - up_left)}

    cond do
      a <= b and a <= c -> left
      b <= c -> up
      true -> up_left
    end
  end

  defp noise(bytes, seed) do
    :rand.seed(:exsss, {seed, seed, seed})
    for _byte <- 1..bytes, into: <<>>, do: <<:rand.uniform(256) - 1>>
  end

  defp failure({:error, {:qa_tool, code, message}}), do: {code, message}

  # -- decoding -----------------------------------------------------------------------

  describe "decode/1" do
    test "reads RGBA rows under every row filter and the scale in pHYs" do
      rgba = noise(9 * 8 * 4, 7)
      phys = {"pHYs", <<5669::32, 5669::32, 1>>}
      text = {"tEXt", "Software\0another encoder"}

      assert {:ok, %{width: 9, height: 8, rgba: ^rgba, scale: 2}} = Picture.decode(png(9, 8, 6, 8, rgba, filters: [0, 1, 2, 3, 4, 4, 4, 4], before: [phys, text]))

      # The same picture written by Symphony reads back the same.
      assert {:ok, %{rgba: ^rgba, scale: 3}} = 9 |> Picture.encode(8, rgba, 3) |> Picture.decode()
    end

    test "reads RGB, grey, grey with alpha, 16-bit and palette pictures as RGBA" do
      assert {:ok, %{rgba: <<1, 2, 3, 255, 4, 5, 6, 255>>, scale: nil}} = Picture.decode(png(2, 1, 2, 8, <<1, 2, 3, 4, 5, 6>>, filters: [1]))
      assert {:ok, %{rgba: <<9, 9, 9, 255>>}} = Picture.decode(png(1, 1, 0, 8, <<9>>))
      assert {:ok, %{rgba: <<9, 9, 9, 128>>}} = Picture.decode(png(1, 1, 4, 8, <<9, 128>>))
      assert {:ok, %{rgba: <<1, 2, 3, 4>>}} = Picture.decode(png(1, 1, 6, 16, <<1, 99, 2, 99, 3, 99, 4, 99>>, filters: [3]))

      palette = [before: [{"PLTE", <<10, 20, 30, 40, 50, 60>>}, {"tRNS", <<0>>}]]
      assert {:ok, %{rgba: <<10, 20, 30, 0, 40, 50, 60, 255, 0, 0, 0, 255>>}} = Picture.decode(png(3, 1, 3, 8, <<0, 1, 7>>, palette))

      # A density in another unit than the metre names no scale.
      assert {:ok, %{scale: nil}} = Picture.decode(png(1, 1, 0, 8, <<9>>, before: [{"pHYs", <<1::32, 1::32, 0>>}]))
    end

    test "reads a picture larger than one piece of its zlib stream" do
      rgba = drawing(300, 200, [{10, 10, 5, 5}])
      assert {:ok, %{width: 300, height: 200, rgba: ^rgba}} = Picture.decode(png(300, 200, 6, 8, rgba))
    end

    test "says why it cannot read a picture" do
      ok = png(1, 1, 0, 8, <<9>>)
      assert Picture.decode("GIF89a") == {:error, "it is not a PNG"}
      assert Picture.decode(binary_part(ok, 0, byte_size(ok) - 6)) == {:error, "it ends before its last chunk"}
      assert Picture.decode(@signature <> IO.iodata_to_binary(chunk("IEND", ""))) == {:error, "its header is missing or malformed"}
      assert Picture.decode(png(0, 1, 0, 8, "")) == {:error, "its header is missing or malformed"}
      assert Picture.decode(png(1, 1, 0, 8, <<9>>, interlace: 1)) == {:error, "it is interlaced, which Symphony does not read"}
      assert Picture.decode(png(8, 1, 0, 1, <<0>>)) == {:error, "Symphony does not read colour type 0 at 1 bits"}
      assert Picture.decode(png(1, 1, 3, 16, <<0, 0>>)) == {:error, "Symphony does not read colour type 3 at 16 bits"}
      assert Picture.decode(png(1, 1, 5, 8, <<0>>)) == {:error, "Symphony does not read colour type 5 at 8 bits"}

      huge = @signature <> IO.iodata_to_binary([chunk("IHDR", <<10_000::32, 5_000::32, 8, 6, 0, 0, 0>>), chunk("IEND", "")])
      assert Picture.decode(huge) == {:error, "it is 10000×5000 pixels, over 40000000"}

      assert Picture.decode(png(1, 1, 0, 8, <<9>>, idat: "not zlib")) == {:error, "its image data is not a zlib stream"}
      assert Picture.decode(png(1, 1, 0, 8, <<9>>, idat: :zlib.compress(<<0, 9, 9, 9>>))) == {:error, "its image data is longer than its rows"}
      assert Picture.decode(png(2, 2, 0, 8, <<9, 9, 9, 9>>, idat: :zlib.compress(<<0, 9>>))) == {:error, "its image data is shorter than its rows"}
      assert Picture.decode(png(1, 1, 0, 8, <<9>>, idat: :zlib.compress(<<7, 9>>))) == {:error, "a row has the unknown filter 7"}
      assert Picture.decode(png(1, 1, 3, 8, <<0>>)) == {:error, "it has a palette colour type and no palette"}
    end
  end

  # -- reading an evidence picture ---------------------------------------------------------

  describe "Checks.read_evidence/3" do
    test "reads a picture in qa-evidence/ by either path", %{worktree: worktree} do
      save!(worktree, "home.png", "bytes")
      assert Checks.read_evidence(worktree, "qa-evidence/home.png", 100) == {:ok, "qa-evidence/home.png", "bytes"}
      assert Checks.read_evidence(worktree, "home.png", 100) == {:ok, "qa-evidence/home.png", "bytes"}
    end

    test "refuses anything but a picture of its own inside qa-evidence/", %{worktree: worktree} do
      evidence = Path.join(worktree, "qa-evidence")
      File.write!(Path.join(worktree, "outside.png"), "secret")
      save!(worktree, "big.png", "0123456789")
      File.ln_s!(Path.join(worktree, "outside.png"), Path.join(evidence, "link.png"))
      File.mkdir_p!(Path.join(evidence, "folder.png"))
      save!(worktree, "one.png", "x")
      File.ln!(Path.join(evidence, "one.png"), Path.join(evidence, "two.png"))
      save!(worktree, "locked.png", "x")
      File.chmod!(Path.join(evidence, "locked.png"), 0o000)
      on_exit(fn -> File.chmod(Path.join(evidence, "locked.png"), 0o600) end)

      assert {"invalid_arguments", _message} = failure(Checks.read_evidence(worktree, nil, 100))
      assert {"invalid_arguments", _message} = failure(Checks.read_evidence(worktree, "", 100))
      assert {"invalid_arguments", "`path` must not contain NUL bytes."} = failure(Checks.read_evidence(worktree, "a\0.png", 100))
      assert {"qa_picture_missing", message} = failure(Checks.read_evidence(worktree, "gone.png", 100))
      assert message =~ "qa-evidence/gone.png does not exist"
      assert {"qa_picture_refused", message} = failure(Checks.read_evidence(worktree, "qa-evidence/../outside.png", 100))
      assert message =~ "is outside qa-evidence/"
      assert {"qa_picture_refused", message} = failure(Checks.read_evidence(worktree, "link.png", 100))
      assert message =~ "is a symlink"
      assert {"qa_picture_refused", message} = failure(Checks.read_evidence(worktree, "big.png", 5))
      assert message =~ "is over 5 bytes"
      assert {"qa_picture_refused", message} = failure(Checks.read_evidence(worktree, "folder.png", 100))
      assert message =~ "is not a picture file of its own"
      assert {"qa_picture_refused", _message} = failure(Checks.read_evidence(worktree, "two.png", 100))
      assert {"qa_picture_refused", message} = failure(Checks.read_evidence(worktree, "big.png/inside.png", 100))
      assert message =~ "could not be read"
      assert {"qa_picture_refused", message} = failure(Checks.read_evidence(worktree, "locked.png", 100))
      assert message =~ "could not be read"
    end
  end

  # -- qa_crop ------------------------------------------------------------------------

  describe "crop/2" do
    test "saves the rectangle, enlarged, as a new evidence picture at the picture's scale", %{worktree: worktree} do
      # 20×10 pixels at 2 pixels per point: 10×5 pt, a black box at 2.5,1 pt of 2.5×2.5 pt.
      rgba = drawing(20, 10, [{5, 2, 5, 5}])
      path = save!(worktree, "row.png", Picture.encode(20, 10, rgba, 2))

      assert {:ok, result} = Picture.crop(worktree, %{"path" => path, "name" => "row-crop", "x" => 2, "y" => 0.5, "width" => 3, "height" => 3})

      assert %{
               "path" => "qa-evidence/row-crop.png",
               "source" => "qa-evidence/row.png",
               "rect" => %{"x" => 2, "y" => 0.5, "width" => 3, "height" => 3},
               "zoom" => 2,
               "pixels" => %{"w" => 12, "h" => 12},
               "scale" => 4
             } = result

      # Pixels 4..9 by 1..6 of the picture, each drawn 2×2.
      assert {:ok, %{width: 12, height: 12, scale: 4, rgba: cropped}} = Picture.decode(File.read!(Path.join(worktree, "qa-evidence/row-crop.png")))
      black? = fn x, y -> inside?({5, 2, 5, 5}, div(x, 2) + 4, div(y, 2) + 1) end
      expected = for y <- 0..11, x <- 0..11, into: <<>>, do: if(black?.(x, y), do: @black, else: @white)
      assert cropped == expected

      # zoom 1 is the crop as it is; `scale` overrides the picture's own.
      assert {:ok, %{"pixels" => %{"w" => 3, "h" => 2}, "scale" => 1}} =
               Picture.crop(worktree, %{"path" => "row.png", "name" => "plain", "x" => 4, "y" => 1, "width" => 3, "height" => 2, "zoom" => 1, "scale" => 1})

      assert {:ok, %{rgba: plain}} = Picture.decode(File.read!(Path.join(worktree, "qa-evidence/plain.png")))
      assert plain == drawing(3, 2, [{1, 1, 2, 1}])
    end

    test "names each refusal", %{worktree: worktree} do
      path = save!(worktree, "row.png", Picture.encode(20, 10, drawing(20, 10, []), 1))
      save!(worktree, "not-a-picture.png", "hello")
      args = %{"path" => path, "name" => "crop", "x" => 0, "y" => 0, "width" => 5, "height" => 5}

      assert {"invalid_arguments", _message} = failure(Picture.crop(worktree, Map.delete(args, "name")))
      assert {"invalid_arguments", "`zoom` must be an integer from 1 to 8."} = failure(Picture.crop(worktree, Map.put(args, "zoom", 9)))

      for bad <- [%{"width" => 0}, %{"x" => -1}, %{"height" => "5"}, %{"y" => nil}] do
        assert {"invalid_arguments", message} = failure(Picture.crop(worktree, Map.merge(args, bad)))
        assert message =~ "the crop needs `x` and `y`"
      end

      assert {"qa_picture_missing", _message} = failure(Picture.crop(worktree, Map.put(args, "path", "gone.png")))
      assert {"qa_picture_unreadable", message} = failure(Picture.crop(worktree, Map.put(args, "path", "not-a-picture.png")))
      assert message == "qa-evidence/not-a-picture.png could not be read as a picture: it is not a PNG."
      assert {"invalid_arguments", message} = failure(Picture.crop(worktree, Map.put(args, "scale", 5)))
      assert message =~ "`scale` must be an integer from 1 to 4"

      assert {"qa_picture_out_of_bounds", message} = failure(Picture.crop(worktree, Map.merge(args, %{"x" => 16, "width" => 5})))
      assert message == "The rectangle at 16,0 of 5×5 pt reaches past the picture, which is 20.0×10.0 pt (20×10 pixels at scale 1)."
      assert {"qa_picture_out_of_bounds", _message} = failure(Picture.crop(worktree, Map.merge(args, %{"height" => 11})))

      assert {:ok, _crop} = Picture.crop(worktree, args)
      assert {"qa_screenshot_exists", _message} = failure(Picture.crop(worktree, args))
    end

    test "refuses a crop too large to save", %{worktree: worktree} do
      path = save!(worktree, "wide.png", Picture.encode(600, 500, :binary.copy(@white, 600 * 500), 1))
      args = %{"path" => path, "name" => "wide-crop", "x" => 0, "y" => 0, "width" => 600, "height" => 500, "zoom" => 8}
      assert {"invalid_arguments", message} = failure(Picture.crop(worktree, args))
      assert message == "The crop would be 4800×4000 pixels, over 16000000: crop a smaller rectangle or lower `zoom`."
    end
  end

  # -- qa_measure -----------------------------------------------------------------------

  describe "measure/2" do
    setup %{worktree: worktree} do
      # 40×20 pixels at 2 per point (20×10 pt): a box at pixels 4..9 by 2..7, and one at 7..12 by 10..15,
      # whose left edge sits 1.5 pt right of the first's.
      rgba = drawing(40, 20, [{4, 2, 6, 6}, {7, 10, 6, 6}])
      %{path: save!(worktree, "labels.png", Picture.encode(40, 20, rgba, 2))}
    end

    test "measures the distance between two points, in points", %{worktree: worktree, path: path} do
      assert {:ok, result} = Picture.measure(worktree, %{"path" => path, "points" => [%{"x" => 1, "y" => 1}, %{"x" => 4, "y" => 5}]})

      assert result == %{
               "path" => "qa-evidence/labels.png",
               "scale" => 2,
               "size" => %{"w" => 20.0, "h" => 10.0},
               "precision" => 0.5,
               "from" => %{"x" => 1, "y" => 1},
               "to" => %{"x" => 4, "y" => 5},
               "dx" => 3.0,
               "dy" => 4.0,
               "distance" => 5.0
             }

      for point <- [%{"x" => 21, "y" => 1}, %{"x" => 1, "y" => -1}] do
        assert {"qa_picture_out_of_bounds", message} = failure(Picture.measure(worktree, %{"path" => path, "points" => [%{"x" => 1, "y" => 1}, point]}))
        assert message =~ "is outside the picture, which is 20.0×10.0 pt"
      end
    end

    test "finds edges and says whether they are aligned, and by how much", %{worktree: worktree, path: path} do
      first = %{"x" => 0, "y" => 0, "width" => 10, "height" => 4.5}
      second = %{"x" => 0, "y" => 4.5, "width" => 10, "height" => 4.5}

      assert {:ok, result} = Picture.measure(worktree, %{"path" => path, "edges" => [Map.put(first, "side", "left"), Map.put(second, "side", "left")]})
      assert %{"axis" => "x", "offset" => 1.5, "within" => 1, "aligned" => false, "distance" => 1.5, "edges" => [one, two]} = result
      assert one == %{"side" => "left", "at" => 2.0, "region" => first}
      assert two["at"] == 3.5

      assert {:ok, %{"aligned" => true, "within" => 2}} =
               Picture.measure(worktree, %{"path" => path, "within" => 2, "edges" => [Map.put(first, "side", "left"), Map.put(second, "side", "left")]})

      # The right, top and bottom edges; three edges give no distance.
      assert {:ok, %{"edges" => [%{"at" => 5.0}, %{"at" => 6.5}, %{"at" => 6.5}], "offset" => 1.5}} =
               Picture.measure(worktree, %{
                 "path" => path,
                 "edges" => [Map.put(first, "side", "right"), Map.put(second, "side", "right"), Map.put(second, "side", "right")]
               })

      assert {:ok, %{"axis" => "y", "edges" => [%{"at" => 1.0}, %{"at" => 8.0}], "distance" => 7.0}} =
               Picture.measure(worktree, %{
                 "path" => path,
                 "edges" => [Map.put(first, "side", "top"), Map.put(second, "side", "bottom")]
               })

      # One edge is its position alone.
      assert {:ok, %{"edges" => [%{"at" => 2.0}], "axis" => "x"} = single} = Picture.measure(worktree, %{"path" => path, "edges" => [Map.put(first, "side", "left")]})
      refute Map.has_key?(single, "aligned")
    end

    test "names each refusal", %{worktree: worktree, path: path} do
      region = %{"x" => 0, "y" => 0, "width" => 10, "height" => 4.5, "side" => "left"}

      for args <- [%{}, %{"points" => [], "edges" => []}, %{"points" => "a"}] do
        assert {"invalid_arguments", message} = failure(Picture.measure(worktree, Map.put(args, "path", path)))
        assert message =~ "Pass `points` (two points) or `edges`"
      end

      assert {"invalid_arguments", message} = failure(Picture.measure(worktree, %{"path" => path, "points" => [%{"x" => 1, "y" => 1}]}))
      assert message =~ "`points` must be two objects"
      assert {"invalid_arguments", message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => []}))
      assert message =~ "`edges` must list 1 to 8 regions"
      assert {"invalid_arguments", _message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => List.duplicate(region, 9)}))
      assert {"invalid_arguments", message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [region, Map.delete(region, "side")]}))
      assert message == "Edge 2 needs a `side`: left, right, top or bottom."
      assert {"invalid_arguments", message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [Map.put(region, "width", 0)]}))
      assert message =~ "Edge 1 needs `x` and `y`"
      assert {"invalid_arguments", message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [region, Map.put(region, "side", "top")]}))
      assert message =~ "all left or right (x), or all top or bottom (y)"
      assert {"invalid_arguments", _message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [region], "tolerance" => 256}))
      assert {"invalid_arguments", message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [region], "within" => -1}))
      assert message =~ "`within` must be a number of points"

      assert {"qa_picture_missing", _message} = failure(Picture.measure(worktree, %{"path" => "gone.png", "edges" => [region]}))
      assert {"qa_picture_out_of_bounds", _message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [Map.put(region, "width", 30)]}))

      blank = Map.merge(region, %{"x" => 15, "width" => 5})
      assert {"qa_measure_no_edge", message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [blank]}))
      assert message =~ "Edge 1: every pixel of its region is within 24 of its left corner's colour"
    end

    test "refuses a region too large to scan", %{worktree: worktree} do
      path = save!(worktree, "large.png", Picture.encode(2001, 2000, :binary.copy(@white, 2001 * 2000), 1))
      region = %{"x" => 0, "y" => 0, "width" => 2001, "height" => 2000, "side" => "left"}
      assert {"invalid_arguments", message} = failure(Picture.measure(worktree, %{"path" => path, "edges" => [region]}))
      assert message =~ "Edge 1's region is over 4000000 pixels"
    end
  end
end
