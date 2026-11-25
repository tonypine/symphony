defmodule SymphonyElixir.QaDriver.Elements do
  @moduledoc """
  The Mac app's element report, read for the QA tools (TP-1677): `qa_elements`, `qa_scroll_to`,
  `qa_measure_elements` and the app state `qa_check_app` and `qa_wait_check` return.

  In QA mode the app writes `<QA root>/elements/<pid>.json` (`QAElementReport` in
  `macos/Sources/SymphonyBarCore/QAElementReport.swift`) a moment after its screen changes: the
  named elements on screen, each with its stable name (also its accessibility identifier), its
  frame, whether any of it shows, whether all of it does and the part that shows, and the frames
  of its named parts (two views with one name are told apart from the top: `name#2`), in screen
  points from the top left of the main display, as `qa_ax_tree` frames and `qa_click` points are;
  the state the app holds (the page shown, the ticket open, the selected and focused named
  elements); and the naming scheme.
  A release build, or a build from before the report, writes none: the tools answer
  `qa_elements_missing`.

  The report is on the QA host, so it is copied aside in the run directory and read from there
  (`SymphonyElixir.QaDriver.Remote.read/2` takes away what it reads).
  """

  @folder "elements"
  # Copies the app's report (`$1/elements/$2.json`) to `$3`, or says there is none.
  @copy_script """
  src="$1/elements/$2.json"
  if [ ! -f "$src" ]; then printf 'symphony-qa-no-report\\n'; exit 0; fi
  cp "$src" "$3" && printf 'symphony-qa-report\\n'
  """
  @timeout_ms 30_000
  @output_limit 8_000
  # Report frames to a hundredth of a point; alignment within half a point by default.
  @default_within 0.5
  @max_within 100
  @default_max_scrolls 20
  @max_scrolls 50
  # How long the app takes to write its report again after a scroll (it waits 150 ms for quiet).
  @settle_ms 400
  @directions ~w(down up)

  @type tool_error :: {:error, {:qa_tool, String.t(), String.t()}}
  @type report :: map()

  @doc "The folder under the QA root the app writes its element report into, one file per process."
  @spec folder() :: String.t()
  def folder, do: @folder

  @doc """
  Reads the element report of the app with `pid` in `qa_root`, through the QA host in `config`.
  `qa_elements_missing` when the app wrote none, `qa_elements_unreadable` when it cannot be read.
  """
  @spec read(map(), Path.t(), pos_integer()) :: {:ok, report()} | tool_error()
  def read(config, qa_root, pid) do
    taken = Path.join(config.host_dir, "elements-#{pid}-#{System.unique_integer([:positive])}.json")
    opts = [timeout_ms: @timeout_ms, output_limit: @output_limit]

    case config.host.cmd.("/bin/sh", ["-c", @copy_script, "sh", qa_root, Integer.to_string(pid), taken], opts) do
      {:ok, {output, 0}} ->
        cond do
          output =~ "symphony-qa-report" -> decode(config.host.read.(taken))
          output =~ "symphony-qa-no-report" -> missing()
          true -> unreadable("the copy said #{inspect(String.trim(output))}")
        end

      {:ok, {output, status}} ->
        unreadable("the copy failed (exit #{status}): #{String.trim(output)}")

      {:error, reason} ->
        unreadable(inspect(reason))
    end
  end

  defp decode({:ok, bytes}) do
    case Jason.decode(bytes) do
      {:ok, %{"version" => 1, "elements" => elements} = report} when is_list(elements) -> {:ok, report}
      {:ok, %{"version" => version}} -> unreadable("it is version #{inspect(version)}; this driver reads version 1")
      _other -> unreadable("it is not the app's JSON report")
    end
  end

  defp decode({:error, reason}), do: unreadable(inspect(reason))

  defp missing do
    tool_error(
      "qa_elements_missing",
      "The app wrote no element report in its QA root: a release build, or one from before QA element names. " <>
        "Find elements with qa_ax_tree instead, and judge sizes and alignments with qa_screenshot, qa_crop and qa_measure."
    )
  end

  defp unreadable(why), do: tool_error("qa_elements_unreadable", "The app's element report could not be read: #{why}.")

  @doc """
  What `qa_elements` returns from `report`: the elements whose name starts with `prefix` (all
  without one), only the visible ones when `visible_only`, with the windows, the app's state, the
  naming scheme and when the app wrote it.
  """
  @spec listing(report(), String.t() | nil, boolean()) :: map()
  def listing(report, prefix, visible_only) do
    elements =
      report
      |> elements()
      |> Enum.filter(&((is_nil(prefix) or String.starts_with?(&1["name"], prefix)) and (not visible_only or &1["visible"] == true)))

    %{
      "elements" => elements,
      "count" => length(elements),
      "windows" => Map.get(report, "windows", []),
      "state" => app_state(report),
      "names" => Map.get(report, "names", []),
      "at" => report["at"]
    }
  end

  @doc "The app's state from `report`, with when the app wrote it."
  @spec app_state(report()) :: map()
  def app_state(report), do: report |> Map.get("state", %{}) |> Map.put("at", report["at"])

  @doc """
  What `qa_check_app` and `qa_wait_check` add about the app's state: `app_state` from the report, or
  nil with `app_state_note` saying why there is none.
  """
  @spec state_fields({:ok, report()} | tool_error()) :: map()
  def state_fields({:ok, report}), do: %{"app_state" => app_state(report)}
  def state_fields({:error, {:qa_tool, _code, message}}), do: %{"app_state" => nil, "app_state_note" => message}

  @doc "The element named `name` in `report`, or nil."
  @spec find(report(), String.t()) :: map() | nil
  def find(report, name), do: Enum.find(elements(report), &(&1["name"] == name))

  defp elements(report), do: Enum.filter(report["elements"], &(is_map(&1) and is_binary(&1["name"])))

  # -- measuring ---------------------------------------------------------------

  @doc """
  Checks `qa_measure_elements`' arguments: `a` and `b`, each a name or `name:part`, and `within`
  (points, half a point by default).
  """
  @spec measure_arguments(map()) :: {:ok, {String.t(), String.t(), number()}} | tool_error()
  def measure_arguments(args) do
    with {:ok, a} <- target_argument(args, "a"),
         {:ok, b} <- target_argument(args, "b"),
         {:ok, within} <- within_argument(Map.get(args, "within")) do
      {:ok, {a, b, within}}
    end
  end

  defp target_argument(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" and byte_size(value) <= 200 -> {:ok, value}
      _other -> tool_error("invalid_arguments", "`#{key}` must be an element's name from qa_elements, or `name:part` for one of its parts.")
    end
  end

  defp within_argument(nil), do: {:ok, @default_within}
  defp within_argument(value) when is_number(value) and value >= 0 and value <= @max_within, do: {:ok, value}
  defp within_argument(_value), do: tool_error("invalid_arguments", "`within` must be a number of points from 0 to #{@max_within}.")

  @doc """
  The distance and the alignment between `a` and `b` (each a name or `name:part`) in `report`,
  computed from the frames the app reported: each edge's and centre's offset from `a` to `b`, which
  of them match within `within` points, the gaps between them, the difference in size, and the
  distance between their centres.
  """
  @spec measure(report(), String.t(), String.t(), number()) :: {:ok, map()} | tool_error()
  def measure(report, a, b, within) do
    with {:ok, first} <- frame_of(report, a),
         {:ok, second} <- frame_of(report, b) do
      {:ok, compare(first, second, within) |> Map.merge(%{"a" => target(a, first), "b" => target(b, second), "at" => report["at"]})}
    end
  end

  defp target(name, frame), do: %{"name" => name, "frame" => frame}

  defp frame_of(report, target) do
    {name, part} =
      case String.split(target, ":", parts: 2) do
        [name, part] -> {name, part}
        [name] -> {name, nil}
      end

    case {find(report, name), part} do
      {nil, _part} ->
        tool_error("qa_element_not_found", "No element named #{name} is on screen. List the names with qa_elements, or bring it into view with qa_scroll_to.")

      {element, nil} ->
        rect(element["frame"], target)

      {element, part} ->
        case get_in(element, ["parts", part]) do
          nil -> tool_error("qa_element_not_found", "#{name} has no part #{part}; its parts are #{part_names(element)}.")
          frame -> rect(frame, target)
        end
    end
  end

  defp part_names(element) do
    case element |> Map.get("parts", %{}) |> Map.keys() |> Enum.sort() do
      [] -> "none"
      names -> Enum.join(names, ", ")
    end
  end

  defp rect(%{"x" => x, "y" => y, "w" => w, "h" => h} = frame, _target) when is_number(x) and is_number(y) and is_number(w) and is_number(h),
    do: {:ok, frame}

  defp rect(_frame, target), do: unreadable("#{target}'s frame is not x, y, w and h")

  defp compare(a, b, within) do
    edges = %{
      "left" => b["x"] - a["x"],
      "right" => b["x"] + b["w"] - (a["x"] + a["w"]),
      "top" => b["y"] - a["y"],
      "bottom" => b["y"] + b["h"] - (a["y"] + a["h"]),
      "center_x" => b["x"] + b["w"] / 2 - (a["x"] + a["w"] / 2),
      "center_y" => b["y"] + b["h"] / 2 - (a["y"] + a["h"] / 2)
    }

    edges = Map.new(edges, fn {edge, offset} -> {edge, round2(offset)} end)

    %{
      "offsets" => edges,
      "aligned" => edges |> Enum.filter(fn {_edge, offset} -> abs(offset) <= within end) |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      "within" => within,
      # Positive: the space between them on that axis; negative: how far they overlap.
      "gap" => %{
        "x" => round2(max(b["x"] - (a["x"] + a["w"]), a["x"] - (b["x"] + b["w"]))),
        "y" => round2(max(b["y"] - (a["y"] + a["h"]), a["y"] - (b["y"] + b["h"])))
      },
      "size" => %{"w" => round2(b["w"] - a["w"]), "h" => round2(b["h"] - a["h"])},
      "distance" => round2(:math.sqrt(edges["center_x"] ** 2 + edges["center_y"] ** 2))
    }
  end

  defp round2(value), do: Float.round(value * 1.0, 2)

  # -- scrolling to a name -------------------------------------------------------

  @doc """
  Checks `qa_scroll_to`'s arguments: `name`, `at` (an element shown in the scroll area to scroll
  at), `direction` (`down` or `up`: where to look for a name not drawn yet) and `max_scrolls`.
  """
  @spec scroll_arguments(map()) :: {:ok, map()} | tool_error()
  def scroll_arguments(args) do
    with {:ok, name} <- target_argument(args, "name"),
         {:ok, at} <- optional_name(Map.get(args, "at")),
         {:ok, direction} <- direction_argument(Map.get(args, "direction")),
         {:ok, max} <- max_scrolls_argument(Map.get(args, "max_scrolls")) do
      {:ok, %{name: name, at: at, direction: direction, max_scrolls: max}}
    end
  end

  defp optional_name(nil), do: {:ok, nil}
  defp optional_name(value) when is_binary(value) and value != "" and byte_size(value) <= 200, do: {:ok, value}
  defp optional_name(_value), do: tool_error("invalid_arguments", "`at` must be the name of an element shown in the list to scroll.")

  defp direction_argument(nil), do: {:ok, nil}
  defp direction_argument(direction) when direction in @directions, do: {:ok, direction}
  defp direction_argument(_direction), do: tool_error("invalid_arguments", "`direction` must be down or up.")

  defp max_scrolls_argument(nil), do: {:ok, @default_max_scrolls}
  defp max_scrolls_argument(n) when is_integer(n) and n >= 1 and n <= @max_scrolls, do: {:ok, n}
  defp max_scrolls_argument(_n), do: tool_error("invalid_arguments", "`max_scrolls` must be an integer from 1 to #{@max_scrolls}.")

  @doc """
  Brings the element `request.name` into view: reads the report with `read`, and while the element
  is not wholly shown, scrolls with `scroll` (a point `x,y` and a vertical delta in points, positive
  down; it returns the helper's answer) and waits with `sleep` for the app to report again. An
  element the report has but does not show, or shows only in part (`fully_visible` false, `shown`
  the part that shows), is scrolled toward; one not drawn yet (a lazy list draws rows as they come
  into view) is looked for `request.direction` (down by default, then up once the list stops
  moving). Returns the element with its frame and parts, `scrolls` and the app's state, with
  `partly_shown` when the list stopped or the scrolls ran out while only part of it shows (an
  element taller than the list); `qa_element_not_found` when none of it ever shows.
  """
  @type read_fun :: (-> {:ok, report()} | tool_error())
  @type scroll_fun :: (String.t(), integer() -> {:ok, map()} | tool_error())

  @spec scroll_to(map(), read_fun(), scroll_fun(), (non_neg_integer() -> any())) :: {:ok, map()} | tool_error()
  def scroll_to(request, read, scroll, sleep) do
    with {:ok, report} <- read.() do
      io = %{read: read, scroll: scroll, sleep: sleep}
      progress = %{scrolls: 0, direction: request.direction || "down", turned: request.direction != nil}
      step(request, report, io, progress)
    end
  end

  defp step(request, report, io, progress) do
    element = find(report, request.name)

    cond do
      shown?(element) and fully_shown?(element) -> {:ok, found(element, report, progress)}
      progress.scrolls >= request.max_scrolls -> partly_or_not_found(request, report, progress, "after #{progress.scrolls} scrolls")
      true -> scroll_once(request, report, element, io, progress)
    end
  end

  defp shown?(element), do: is_map(element) and element["visible"] == true
  # A report from before `fully_visible` says only whether any of it shows.
  defp fully_shown?(element), do: Map.get(element, "fully_visible", true) == true

  defp found(element, report, progress), do: Map.merge(element, %{"scrolls" => progress.scrolls, "state" => app_state(report)})

  # The scrolls ran out, or the list stopped: an element partly shown is returned as it is, with a
  # word that only part of it shows; one not shown at all is not found.
  defp partly_or_not_found(request, report, progress, why) do
    element = find(report, request.name)

    if shown?(element) do
      note = "Only part of #{request.name} shows (`shown`) #{why}: it is taller than the list that holds it, or the list ends there."
      {:ok, element |> found(report, progress) |> Map.put("partly_shown", note)}
    else
      not_found(request, why)
    end
  end

  defp scroll_once(request, report, element, io, progress) do
    with {:ok, point} <- scroll_point(report, request.at),
         {direction, dy} = delta(report, element, progress.direction),
         {:ok, answer} <- io.scroll.(point, dy),
         _slept = io.sleep.(@settle_ms),
         {:ok, next} <- io.read.() do
      progress = %{progress | scrolls: progress.scrolls + 1, direction: direction}
      moved(request, report, next, element, answer, io, progress)
    end
  end

  # A list that did not move is at its end that way: a name not drawn yet is looked for the other
  # way once, unless the call named the direction.
  defp moved(request, report, next, element, answer, io, progress) do
    still? = still?(answer, report, next)

    cond do
      not still? -> step(request, next, io, progress)
      # Only a search the call gave no direction turns, and it starts down.
      element == nil and not progress.turned -> step(request, next, io, %{progress | direction: "up", turned: true})
      true -> partly_or_not_found(request, next, progress, "once the list stopped moving (#{progress.scrolls} scrolls)")
    end
  end

  defp still?(%{"moved" => %{"y" => 0}}, _report, _next), do: true
  defp still?(%{"moved" => %{"y" => _moved}}, _report, _next), do: false
  defp still?(_answer, report, next), do: signature(report) == signature(next)

  defp signature(report), do: report |> elements() |> Enum.map(&{&1["name"], get_in(&1, ["frame", "y"])})

  defp not_found(request, why) do
    tool_error(
      "qa_element_not_found",
      "#{request.name} did not come into view #{why}. Check the name with qa_elements (its `names` give the scheme), " <>
        "or pass `at`: a shown element in the list that holds it."
    )
  end

  # Where to scroll: the middle of `at`, or of the window the report's elements are in.
  defp scroll_point(report, nil) do
    windows = Map.get(report, "windows", [])

    case Enum.find(windows, &(&1["key"] == true)) || List.first(windows) do
      %{"frame" => frame} -> {:ok, centre(frame)}
      nil -> tool_error("qa_element_not_found", "The app reports no window with named elements. Open the page first, or pass `at`.")
    end
  end

  defp scroll_point(report, at) do
    case find(report, at) do
      %{"visible" => true, "frame" => frame} -> {:ok, centre(frame)}
      _other -> tool_error("qa_element_not_found", "#{at} is not shown, so it cannot be scrolled at. Pass a shown element of the list, or leave `at` out.")
    end
  end

  defp centre(%{"x" => x, "y" => y, "w" => w, "h" => h}), do: "#{round(x + w / 2)},#{round(y + h / 2)}"

  # An element partly shown: toward its cut edge, as far as it is cut. An element the report has:
  # toward it, as far as it is (a page at most). A name not drawn yet: a page in the direction
  # searched.
  defp delta(report, element, direction) do
    page = page(report)

    case element do
      %{"visible" => true, "frame" => %{"y" => y, "h" => h}, "shown" => %{"y" => shown_y, "h" => shown_h}} ->
        cond do
          y + h > shown_y + shown_h + 0.5 -> {"down", clamp(round(y + h - (shown_y + shown_h)) + 8, page)}
          y < shown_y - 0.5 -> {"up", -clamp(round(shown_y - y) + 8, page)}
          true -> {direction, if(direction == "up", do: -page, else: page)}
        end

      %{"frame" => %{"y" => y, "h" => h}} ->
        {top, bottom} = window_span(report, element)

        cond do
          y + h > bottom -> {"down", clamp(round(y + h - bottom) + 40, page)}
          y < top -> {"up", -clamp(round(top - y) + 40, page)}
          true -> {direction, if(direction == "up", do: -page, else: page)}
        end

      nil ->
        {direction, if(direction == "up", do: -page, else: page)}
    end
  end

  defp clamp(value, page), do: value |> max(40) |> min(page)

  defp page(report) do
    case scroll_window(report) do
      %{"frame" => %{"h" => h}} when is_number(h) -> max(round(h * 0.6), 100)
      _none -> 400
    end
  end

  defp window_span(report, element) do
    window = Enum.find(Map.get(report, "windows", []), &(&1["number"] == element["window"])) || scroll_window(report)

    case window do
      %{"frame" => %{"y" => y, "h" => h}} -> {y, y + h}
      _none -> {0, 0}
    end
  end

  defp scroll_window(report) do
    windows = Map.get(report, "windows", [])
    Enum.find(windows, &(&1["key"] == true)) || List.first(windows)
  end

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}
end
