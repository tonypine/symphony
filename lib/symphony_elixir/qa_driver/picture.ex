defmodule SymphonyElixir.QaDriver.Picture do
  @moduledoc """
  `qa_crop` and `qa_measure` of `SymphonyElixir.QaDriver`: work on a picture a QA tool already
  saved in the worktree's `qa-evidence/` (a `qa_screenshot`, a `qa_gallery` board, an earlier
  crop), on the Symphony host, whatever host the app runs on.

  The agent's sandbox cannot write a picture (`sips` is refused there), so Symphony reads and
  writes the PNG itself: it decodes it here, in Elixir (`:zlib` ships with OTP), and never runs a
  tool for it. It reads 8- and 16-bit greyscale, RGB, grey with alpha and RGBA pictures, and 8-bit
  palette ones, not interlaced; a crop is saved as an 8-bit RGBA PNG.

  Coordinates are points from the picture's top-left corner. A picture's scale (pixels per point)
  comes from its `pHYs` chunk (144 dpi is 2), else 1; the call's `scale` overrides it. For a
  window's screenshot, a point on screen is the point minus the window frame's `x` and `y`.
  """

  import Bitwise

  alias SymphonyElixir.QaDriver.Checks

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  # A metre in inches, for the `pHYs` chunk's pixels per metre.
  @metre_inches 39.3701
  @point_dpi 72
  @picture_limit 64_000_000
  @max_pixels 40_000_000
  @max_output_pixels 16_000_000
  @max_region_pixels 4_000_000
  @max_zoom 8
  @default_zoom 2
  @max_scale 4
  @default_tolerance 24
  @default_within 1
  @max_edges 8
  @axis %{"left" => "x", "right" => "x", "top" => "y", "bottom" => "y"}
  @chunk_keys %{"IHDR" => :ihdr, "PLTE" => :plte, "tRNS" => :trns, "pHYs" => :phys}

  @type picture :: %{width: pos_integer(), height: pos_integer(), rgba: binary(), scale: pos_integer() | nil}
  @type tool_error :: {:error, {:qa_tool, String.t(), String.t()}}

  @doc """
  Decodes a PNG into its size, its pixels as 8-bit RGBA rows and its scale (pixels per point,
  from `pHYs`; nil without one). Returns `{:error, why}` for anything it does not read.
  """
  @spec decode(binary()) :: {:ok, picture()} | {:error, String.t()}
  def decode(<<@signature, rest::binary>>) do
    with {:ok, chunks} <- chunks(rest, %{idat: []}),
         {:ok, header} <- header(Map.get(chunks, :ihdr)),
         {:ok, raw} <- inflate(Enum.reverse(chunks.idat), header.height * (header.stride + 1)),
         {:ok, data} <- unfilter(raw, header),
         {:ok, rgba} <- to_rgba(data, header, chunks) do
      {:ok, %{width: header.width, height: header.height, rgba: rgba, scale: scale(Map.get(chunks, :phys))}}
    end
  end

  def decode(_png), do: {:error, "it is not a PNG"}

  @doc "Encodes 8-bit RGBA rows as a PNG whose `pHYs` says `scale` pixels per point."
  @spec encode(pos_integer(), pos_integer(), binary(), pos_integer()) :: binary()
  def encode(width, height, rgba, scale) do
    stride = width * 4
    raw = for <<row::binary-size(stride) <- rgba>>, into: <<>>, do: <<0, row::binary>>
    ppm = round(scale * @point_dpi * @metre_inches)

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", <<width::32, height::32, 8, 6, 0, 0, 0>>),
      chunk("pHYs", <<ppm::32, ppm::32, 1>>),
      chunk("IDAT", :zlib.compress(raw)),
      chunk("IEND", "")
    ])
  end

  @doc """
  `qa_crop`: cuts the rectangle (`x`, `y`, `width`, `height`, in points) out of the evidence
  picture at `path`, enlarges it `zoom` times (each pixel drawn as a square, 2 by default) and
  saves it as `qa-evidence/<name>.png`.
  """
  @spec crop(Path.t(), map()) :: {:ok, map()} | tool_error()
  def crop(worktree, args) do
    with {:ok, name} <- Checks.screenshot_name(Map.get(args, "name")),
         {:ok, zoom} <- integer(args, "zoom", 1, @max_zoom, @default_zoom),
         {:ok, rect} <- rect(args, "the crop"),
         {:ok, source, picture} <- load(worktree, Map.get(args, "path")),
         {:ok, scale} <- picture_scale(args, picture),
         {:ok, {px, py, pw, ph}} <- pixel_rect(rect, scale, picture),
         :ok <- output_size(pw * zoom, ph * zoom),
         {:ok, evidence} <- Checks.ensure_evidence_dir(worktree),
         file = name <> ".png",
         png = encode(pw * zoom, ph * zoom, picture |> pixels({px, py, pw, ph}) |> magnify(pw, zoom), scale * zoom),
         :ok <- Checks.write_evidence(Path.join(evidence, file), png, file) do
      {:ok,
       %{
         "path" => Path.join(Checks.evidence_dir(), file),
         "source" => source,
         "rect" => rect_payload(rect),
         "zoom" => zoom,
         "pixels" => %{"w" => pw * zoom, "h" => ph * zoom},
         "scale" => scale * zoom,
         "note" => "Open the crop to judge it. Its scale is #{scale * zoom} pixels per point; its own points start at the crop's top-left corner."
       }}
    end
  end

  @doc """
  `qa_measure`: in the evidence picture at `path`, either the distance between two `points`, or
  the position of each region's `edges` (the first or last pixel unlike the region's corner on
  that side) and, for two or more on one axis, how far apart they are and whether they are
  aligned `within` points (1 by default). Every value is in points.
  """
  @spec measure(Path.t(), map()) :: {:ok, map()} | tool_error()
  def measure(worktree, args) do
    with {:ok, mode} <- measure_mode(args),
         {:ok, source, picture} <- load(worktree, Map.get(args, "path")),
         {:ok, scale} <- picture_scale(args, picture),
         {:ok, payload} <- measure_in(mode, picture, scale) do
      size = %{"w" => round2(picture.width / scale), "h" => round2(picture.height / scale)}
      {:ok, Map.merge(payload, %{"path" => source, "scale" => scale, "size" => size, "precision" => round2(1 / scale)})}
    end
  end

  # -- reading the picture -----------------------------------------------------------

  defp load(worktree, path) do
    with {:ok, source, bytes} <- Checks.read_evidence(worktree, path, @picture_limit) do
      case decode(bytes) do
        {:ok, picture} -> {:ok, source, picture}
        {:error, why} -> tool_error("qa_picture_unreadable", "#{source} could not be read as a picture: #{why}.")
      end
    end
  end

  defp chunks(<<length::32, type::binary-size(4), data::binary-size(length), _crc::32, rest::binary>>, acc) do
    case type do
      "IEND" -> {:ok, acc}
      "IDAT" -> chunks(rest, %{acc | idat: [data | acc.idat]})
      type when is_map_key(@chunk_keys, type) -> chunks(rest, Map.put(acc, @chunk_keys[type], data))
      _other -> chunks(rest, acc)
    end
  end

  defp chunks(_rest, _acc), do: {:error, "it ends before its last chunk"}

  defp header(<<width::32, height::32, depth, color, 0, 0, interlace>>) when width > 0 and height > 0 do
    channels = Map.get(%{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}, color)

    cond do
      interlace != 0 -> {:error, "it is interlaced, which Symphony does not read"}
      channels == nil or depth not in [8, 16] or (color == 3 and depth != 8) -> {:error, "Symphony does not read colour type #{color} at #{depth} bits"}
      width * height > @max_pixels -> {:error, "it is #{width}×#{height} pixels, over #{@max_pixels}"}
      true -> {:ok, layout(width, height, depth, color, channels)}
    end
  end

  defp header(_header), do: {:error, "its header is missing or malformed"}

  defp layout(width, height, depth, color, channels) do
    bits = channels * depth
    %{width: width, height: height, depth: depth, color: color, bpp: div(bits, 8), stride: div(width * bits, 8)}
  end

  # Inflated a piece at a time, so a stream that holds more than the picture's rows is refused
  # before it fills memory.
  defp inflate(parts, expected) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      collect(z, :zlib.safeInflate(z, parts), [], 0, expected)
    rescue
      ErlangError -> {:error, "its image data is not a zlib stream"}
    after
      :zlib.close(z)
    end
  end

  defp collect(z, {state, out}, acc, size, expected) do
    size = size + IO.iodata_length(out)

    cond do
      size > expected -> {:error, "its image data is longer than its rows"}
      state == :continue -> collect(z, :zlib.safeInflate(z, []), [acc | out], size, expected)
      size < expected -> {:error, "its image data is shorter than its rows"}
      true -> {:ok, IO.iodata_to_binary([acc | out])}
    end
  end

  defp unfilter(raw, header), do: unfilter_rows(raw, :binary.copy(<<0>>, header.stride), header, [])

  defp unfilter_rows(<<>>, _prev, _header, rows), do: {:ok, IO.iodata_to_binary(Enum.reverse(rows))}

  defp unfilter_rows(raw, prev, %{stride: stride, bpp: bpp} = header, rows) do
    case raw do
      <<type, line::binary-size(stride), rest::binary>> when type <= 4 ->
        row = unfilter_row(type, line, prev, bpp)
        unfilter_rows(rest, row, header, [row | rows])

      <<type, _rest::binary>> ->
        {:error, "a row has the unknown filter #{type}"}
    end
  end

  defp unfilter_row(0, line, _prev, _bpp), do: line
  defp unfilter_row(type, line, prev, bpp), do: unfilter_bytes(type, line, prev, bpp, 0, <<>>)

  defp unfilter_bytes(_type, <<>>, _prev, _bpp, _index, out), do: out

  defp unfilter_bytes(type, <<byte, rest::binary>>, prev, bpp, index, out) do
    left = if index >= bpp, do: :binary.at(out, index - bpp), else: 0
    up_left = if index >= bpp, do: :binary.at(prev, index - bpp), else: 0
    value = band(byte + predict(type, left, :binary.at(prev, index), up_left), 255)
    unfilter_bytes(type, rest, prev, bpp, index + 1, <<out::binary, value>>)
  end

  defp predict(1, left, _up, _up_left), do: left
  defp predict(2, _left, up, _up_left), do: up
  defp predict(3, left, up, _up_left), do: div(left + up, 2)

  defp predict(4, left, up, up_left) do
    estimate = left + up - up_left
    {to_left, to_up, to_up_left} = {abs(estimate - left), abs(estimate - up), abs(estimate - up_left)}

    cond do
      to_left <= to_up and to_left <= to_up_left -> left
      to_up <= to_up_left -> up
      true -> up_left
    end
  end

  defp to_rgba(data, %{depth: 16} = header, chunks), do: to_rgba(for(<<high, _low <- data>>, into: <<>>, do: <<high>>), %{header | depth: 8}, chunks)
  defp to_rgba(data, %{color: 6}, _chunks), do: {:ok, data}
  defp to_rgba(data, %{color: 2}, _chunks), do: {:ok, for(<<r, g, b <- data>>, into: <<>>, do: <<r, g, b, 255>>)}
  defp to_rgba(data, %{color: 0}, _chunks), do: {:ok, for(<<g <- data>>, into: <<>>, do: <<g, g, g, 255>>)}
  defp to_rgba(data, %{color: 4}, _chunks), do: {:ok, for(<<g, a <- data>>, into: <<>>, do: <<g, g, g, a>>)}

  defp to_rgba(data, %{color: 3}, %{plte: plte} = chunks) do
    alphas = :binary.bin_to_list(Map.get(chunks, :trns, ""))
    colours = for <<r, g, b <- plte>>, do: {r, g, b}

    # An index past the palette is invalid; it is drawn black rather than refused.
    palette =
      colours
      |> Enum.with_index()
      |> Enum.map(fn {{r, g, b}, index} -> <<r, g, b, Enum.at(alphas, index, 255)>> end)
      |> Kernel.++(List.duplicate(<<0, 0, 0, 255>>, 256 - length(colours)))
      |> List.to_tuple()

    {:ok, for(<<index <- data>>, into: <<>>, do: elem(palette, index))}
  end

  defp to_rgba(_data, %{color: 3}, _chunks), do: {:error, "it has a palette colour type and no palette"}

  # 144 dpi is 2 pixels per point; a picture that names no density, or another unit, has none.
  defp scale(<<per_metre::32, _y::32, 1>>) when per_metre > 0, do: max(round(per_metre / @metre_inches / @point_dpi), 1)
  defp scale(_phys), do: nil

  defp chunk(type, data), do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]

  # -- arguments -------------------------------------------------------------------

  defp picture_scale(args, picture) do
    case Map.get(args, "scale") do
      nil -> {:ok, picture.scale || 1}
      scale when is_integer(scale) and scale >= 1 and scale <= @max_scale -> {:ok, scale}
      _other -> tool_error("invalid_arguments", "`scale` must be an integer from 1 to #{@max_scale}: the picture's pixels per point.")
    end
  end

  defp integer(args, key, min, max, default) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _value -> tool_error("invalid_arguments", "`#{key}` must be an integer from #{min} to #{max}.")
    end
  end

  defp rect(args, what) do
    [x, y, w, h] = Enum.map(~w(x y width height), &Map.get(args, &1))

    if Enum.all?([x, y], &(is_number(&1) and &1 >= 0)) and Enum.all?([w, h], &(is_number(&1) and &1 > 0)) do
      {:ok, {x, y, w, h}}
    else
      tool_error("invalid_arguments", "#{what} needs `x` and `y` (0 or more) and `width` and `height` (above 0), in points from the picture's top-left corner.")
    end
  end

  defp rect_payload({x, y, w, h}), do: %{"x" => x, "y" => y, "width" => w, "height" => h}

  defp pixel_rect({x, y, w, h} = rect, scale, picture) do
    {px, py} = {floor(x * scale), floor(y * scale)}
    {pw, ph} = {ceil((x + w) * scale) - px, ceil((y + h) * scale) - py}

    if px + pw <= picture.width and py + ph <= picture.height do
      {:ok, {px, py, pw, ph}}
    else
      {x, y, w, h} = rect

      tool_error(
        "qa_picture_out_of_bounds",
        "The rectangle at #{x},#{y} of #{w}×#{h} pt reaches past the picture, which is #{round2(picture.width / scale)}×#{round2(picture.height / scale)} pt " <>
          "(#{picture.width}×#{picture.height} pixels at scale #{scale})."
      )
    end
  end

  defp output_size(width, height) when width * height <= @max_output_pixels, do: :ok

  defp output_size(width, height),
    do: tool_error("invalid_arguments", "The crop would be #{width}×#{height} pixels, over #{@max_output_pixels}: crop a smaller rectangle or lower `zoom`.")

  defp pixels(%{width: width, rgba: rgba}, {px, py, pw, ph}) do
    for row <- py..(py + ph - 1)//1, into: <<>>, do: binary_part(rgba, (row * width + px) * 4, pw * 4)
  end

  defp magnify(rgba, _width, 1), do: rgba

  defp magnify(rgba, width, zoom) do
    stride = width * 4

    for <<row::binary-size(stride) <- rgba>>, into: <<>> do
      :binary.copy(for(<<pixel::binary-size(4) <- row>>, into: <<>>, do: :binary.copy(pixel, zoom)), zoom)
    end
  end

  # -- measuring --------------------------------------------------------------------

  defp measure_mode(args) do
    case {Map.get(args, "points"), Map.get(args, "edges")} do
      {points, nil} when is_list(points) -> points_mode(points)
      {nil, edges} when is_list(edges) -> edges_mode(edges, args)
      _other -> tool_error("invalid_arguments", "Pass `points` (two points) or `edges` (1 to #{@max_edges} regions), not both.")
    end
  end

  defp points_mode([%{"x" => x1, "y" => y1}, %{"x" => x2, "y" => y2}]) when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2),
    do: {:ok, {:points, {x1, y1}, {x2, y2}}}

  defp points_mode(_points), do: tool_error("invalid_arguments", "`points` must be two objects with numbers `x` and `y`, in points.")

  defp edges_mode(edges, args) when length(edges) in 1..@max_edges do
    with {:ok, regions} <- regions(edges),
         {:ok, tolerance} <- integer(args, "tolerance", 0, 255, @default_tolerance),
         {:ok, within} <- within(Map.get(args, "within")) do
      case regions |> Enum.map(&@axis[&1.side]) |> Enum.uniq() do
        [axis] -> {:ok, {:edges, regions, axis, tolerance, within}}
        _axes -> tool_error("invalid_arguments", "The `edges` of one call are all left or right (x), or all top or bottom (y): call qa_measure once per axis.")
      end
    end
  end

  defp edges_mode(_edges, _args), do: tool_error("invalid_arguments", "`edges` must list 1 to #{@max_edges} regions.")

  defp regions(edges) do
    edges
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {edge, index}, {:ok, regions} ->
      case region(edge, index) do
        {:ok, region} -> {:cont, {:ok, [region | regions]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, regions} -> {:ok, Enum.reverse(regions)}
      error -> error
    end
  end

  defp region(%{"side" => side} = edge, index) when is_map_key(@axis, side) do
    with {:ok, rect} <- rect(edge, "Edge #{index}") do
      {:ok, %{side: side, rect: rect}}
    end
  end

  defp region(_edge, index), do: tool_error("invalid_arguments", "Edge #{index} needs a `side`: left, right, top or bottom.")

  defp within(nil), do: {:ok, @default_within}
  defp within(within) when is_number(within) and within >= 0, do: {:ok, within}
  defp within(_within), do: tool_error("invalid_arguments", "`within` must be a number of points, 0 or more.")

  defp measure_in({:points, {x1, y1} = from, {x2, y2} = to}, picture, scale) do
    with :ok <- in_picture(from, picture, scale),
         :ok <- in_picture(to, picture, scale) do
      {dx, dy} = {x2 - x1, y2 - y1}

      {:ok,
       %{
         "from" => %{"x" => x1, "y" => y1},
         "to" => %{"x" => x2, "y" => y2},
         "dx" => round2(dx),
         "dy" => round2(dy),
         "distance" => round2(:math.sqrt(dx * dx + dy * dy))
       }}
    end
  end

  defp measure_in({:edges, regions, axis, tolerance, within}, picture, scale) do
    regions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {region, index}, {:ok, found} ->
      case edge(picture, scale, region, index, tolerance) do
        {:ok, edge} -> {:cont, {:ok, [edge | found]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, compare(Enum.reverse(found), axis, within)}
      error -> error
    end
  end

  defp in_picture({x, y}, picture, scale) do
    if x >= 0 and y >= 0 and x <= picture.width / scale and y <= picture.height / scale do
      :ok
    else
      tool_error("qa_picture_out_of_bounds", "The point #{x},#{y} is outside the picture, which is #{round2(picture.width / scale)}×#{round2(picture.height / scale)} pt.")
    end
  end

  defp edge(picture, scale, %{side: side, rect: rect}, index, tolerance) do
    with {:ok, {px, py, pw, ph}} <- pixel_rect(rect, scale, picture),
         :ok <- region_size(pw * ph, index) do
      rows = for row <- py..(py + ph - 1)//1, do: {row, binary_part(picture.rgba, (row * picture.width + px) * 4, pw * 4)}
      background = corner(rows, side, pw)

      hits =
        for {row, line} <- rows,
            {pixel, column} <- Enum.with_index(pixels_of(line)),
            differs?(pixel, background, tolerance),
            do: {px + column, row}

      case hits do
        [] ->
          tool_error(
            "qa_measure_no_edge",
            "Edge #{index}: every pixel of its region is within #{tolerance} of its #{side} corner's colour, so there is no edge in it. Widen the region over the thing to measure, or lower `tolerance`."
          )

        hits ->
          {:ok, %{"side" => side, "at" => round2(edge_pixel(hits, side) / scale), "region" => rect_payload(rect)}}
      end
    end
  end

  defp region_size(pixels, _index) when pixels <= @max_region_pixels, do: :ok
  defp region_size(_pixels, index), do: tool_error("invalid_arguments", "Edge #{index}'s region is over #{@max_region_pixels} pixels: narrow it to the thing to measure.")

  defp pixels_of(line), do: for(<<pixel::binary-size(4) <- line>>, do: pixel)

  # The colour the scan starts from: the region's top-left corner, or its top-right for the right
  # side and its bottom-left for the bottom.
  defp corner([{_row, first} | _rest], "right", width), do: binary_part(first, (width - 1) * 4, 4)
  defp corner(rows, "bottom", _width), do: binary_part(rows |> List.last() |> elem(1), 0, 4)
  defp corner([{_row, first} | _rest], _side, _width), do: binary_part(first, 0, 4)

  defp differs?(<<r1, g1, b1, a1>>, <<r2, g2, b2, a2>>, tolerance),
    do: Enum.max([abs(r1 - r2), abs(g1 - g2), abs(b1 - b2), abs(a1 - a2)]) > tolerance

  defp edge_pixel(hits, "left"), do: hits |> Enum.map(&elem(&1, 0)) |> Enum.min()
  defp edge_pixel(hits, "right"), do: (hits |> Enum.map(&elem(&1, 0)) |> Enum.max()) + 1
  defp edge_pixel(hits, "top"), do: hits |> Enum.map(&elem(&1, 1)) |> Enum.min()
  defp edge_pixel(hits, "bottom"), do: (hits |> Enum.map(&elem(&1, 1)) |> Enum.max()) + 1

  defp compare([_one] = edges, axis, _within), do: %{"edges" => edges, "axis" => axis}

  defp compare(edges, axis, within) do
    positions = Enum.map(edges, & &1["at"])
    offset = round2(Enum.max(positions) - Enum.min(positions))
    payload = %{"edges" => edges, "axis" => axis, "offset" => offset, "within" => within, "aligned" => offset <= within}

    case positions do
      [first, second] -> Map.put(payload, "distance", round2(second - first))
      _more -> payload
    end
  end

  defp round2(value), do: Float.round(value / 1, 2)

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}
end
