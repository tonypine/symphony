defmodule SymphonyElixir.QaDriver.Cursor do
  @moduledoc """
  The Mac app's cursor report, read for `qa_hover` (TP-1678): the cursor the app set at the
  pointer and the named element it set it for, so the tool returns the cursor the app reports and
  never compares the system's cursor images.

  In QA mode the app writes `<QA root>/cursor/<pid>.json` (`QACursorReport` in
  `macos/Sources/SymphonyBarCore/QACursorReport.swift`) whenever what it says changes: where the
  pointer is (screen points from the top left of the main display, as `qa_hover` takes them), the
  cursor kind there (`pointing_hand`, `arrow`, `i_beam`, `open_hand`, `closed_hand`,
  `operation_not_allowed`, the resize kinds), the element whose recorded place set it, and the
  source: `recorded` (a recorded place set it), `none` (nothing set one: the arrow) or `unrecorded`
  (the app holds a named cursor none of its recorded places set there). A release build, or a build
  from before the report, writes none.

  The report is on the QA host, so it is copied aside in the run directory and read from there
  (`SymphonyElixir.QaDriver.Remote.read/2` takes away what it reads), as the element report is.
  """

  @folder "cursor"
  # Copies the app's report (`$1/cursor/$2.json`) to `$3`, or says there is none.
  @copy_script """
  src="$1/cursor/$2.json"
  if [ ! -f "$src" ]; then printf 'symphony-qa-no-report\\n'; exit 0; fi
  cp "$src" "$3" && printf 'symphony-qa-report\\n'
  """
  @timeout_ms 30_000
  @output_limit 8_000
  # The app looks at the pointer ten times a second; the driver reads its report again this often,
  # this many times, until the report is for the point the pointer moved to.
  @settle_ms 150
  @settle_reads 6
  # The helper reports the point in whole points, the app to a hundredth.
  @within 1.5

  @doc "The folder under the QA root the app writes its cursor report into, one file per process."
  @spec folder() :: String.t()
  def folder, do: @folder

  @doc """
  What `qa_hover` adds about the cursor once the pointer moved to `hovered` (`%{"x", "y"}`): the
  report of the app with `pid` in `qa_root`, read again (with `config.sleep`) until it is for that
  point.

  - `cursor`: the kind, or nil when there is no report;
  - `cursor_element`: the named element whose recorded place set it, or nil;
  - `cursor_source`: `recorded`, `none`, `unrecorded`, or `no_report` / `bad_report`;
  - `cursor_note`: what that means, in words;
  - `cursor_settled`: whether the report is for the point the pointer moved to;
  - `cursor_recorded`: what the recorded places set there, when the cursor was set outside them;
  - `app_cursor`: the cursor the app holds, named by identity (`unnamed` for another one).
  """
  @spec hover_fields(map(), Path.t(), pos_integer(), map() | nil) :: map()
  def hover_fields(config, qa_root, pid, hovered) do
    case settled_read(config, qa_root, pid, hovered, @settle_reads) do
      {:ok, report, settled} -> fields(report, settled)
      :missing -> no_report()
      {:error, why} -> bad_report(why)
    end
  end

  defp settled_read(config, qa_root, pid, hovered, reads_left) do
    with {:ok, report} <- read(config, qa_root, pid) do
      cond do
        at_point?(report, hovered) ->
          {:ok, report, true}

        reads_left > 1 ->
          config.sleep.(@settle_ms)
          settled_read(config, qa_root, pid, hovered, reads_left - 1)

        true ->
          {:ok, report, false}
      end
    end
  end

  defp at_point?(%{"pointer" => %{"x" => x, "y" => y}}, %{"x" => hx, "y" => hy})
       when is_number(x) and is_number(y) and is_number(hx) and is_number(hy),
       do: abs(x - hx) <= @within and abs(y - hy) <= @within

  defp at_point?(_report, _hovered), do: false

  @doc """
  Reads the cursor report of the app with `pid` in `qa_root`, through the QA host in `config`:
  `:missing` when the app wrote none, `{:error, why}` when it cannot be read.
  """
  @spec read(map(), Path.t(), pos_integer()) :: {:ok, map()} | :missing | {:error, String.t()}
  def read(config, qa_root, pid) do
    taken = Path.join(config.host_dir, "cursor-#{pid}-#{System.unique_integer([:positive])}.json")
    opts = [timeout_ms: @timeout_ms, output_limit: @output_limit]

    case config.host.cmd.("/bin/sh", ["-c", @copy_script, "sh", qa_root, Integer.to_string(pid), taken], opts) do
      {:ok, {output, 0}} ->
        cond do
          output =~ "symphony-qa-report" -> decode(config.host.read.(taken))
          output =~ "symphony-qa-no-report" -> :missing
          true -> {:error, "the copy said #{inspect(String.trim(output))}"}
        end

      {:ok, {output, status}} ->
        {:error, "the copy failed (exit #{status}): #{String.trim(output)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp decode({:ok, bytes}) do
    case Jason.decode(bytes) do
      {:ok, %{"version" => 1, "cursor" => cursor, "source" => source} = report}
      when is_binary(cursor) and is_binary(source) ->
        {:ok, report}

      {:ok, %{"version" => version}} when version != 1 ->
        {:error, "it is version #{inspect(version)}; this driver reads version 1"}

      _other ->
        {:error, "it is not the app's JSON cursor report"}
    end
  end

  defp decode({:error, reason}), do: {:error, inspect(reason)}

  defp fields(report, settled) do
    cursor = report["cursor"]
    element = report["element"]
    source = report["source"]

    base = %{
      "cursor" => cursor,
      "cursor_element" => element,
      "cursor_source" => source,
      "cursor_settled" => settled,
      "app_cursor" => report["app_cursor"],
      "cursor_note" => settled_note(report, settled) <> note(source, cursor, element, report["recorded"])
    }

    if source == "unrecorded", do: Map.put(base, "cursor_recorded", report["recorded"]), else: base
  end

  defp settled_note(_report, true), do: ""

  defp settled_note(%{"pointer" => %{"x" => x, "y" => y}}, false),
    do: "The app's last report is for the pointer at #{x},#{y}, not where it moved: it may not have looked again yet. "

  defp settled_note(_report, false), do: "The app's last report says no pointer position. "

  defp note("recorded", cursor, nil, _recorded), do: "The app set #{cursor} here, outside any named element."
  defp note("recorded", cursor, element, _recorded), do: "The app set #{cursor} here, for #{element}."
  defp note("none", _cursor, _element, _recorded), do: "No element set a cursor here: the arrow, the system's default."

  defp note("unrecorded", cursor, _element, recorded) do
    what =
      case recorded do
        %{"cursor" => kind, "element" => name} when is_binary(name) -> "set #{kind} for #{name}"
        %{"cursor" => kind} -> "set #{kind}, outside any named element"
        _none -> "set none"
      end

    "The app holds #{cursor}, set outside the places that record the cursor (they #{what} here). " <>
      "That is a finding: a place in the app sets this cursor without recording it."
  end

  defp note(source, _cursor, _element, _recorded), do: "The app's report gives the source #{inspect(source)}, which this driver does not know."

  defp no_report do
    %{
      "cursor" => nil,
      "cursor_element" => nil,
      "cursor_source" => "no_report",
      "cursor_note" =>
        "The app wrote no cursor report in its QA root: a release build, or one from before the cursor report. " <>
          "Build and launch the app from this checkout with qa_build and qa_launch_app to read its cursor."
    }
  end

  defp bad_report(why) do
    %{
      "cursor" => nil,
      "cursor_element" => nil,
      "cursor_source" => "bad_report",
      "cursor_note" => "The app's cursor report could not be read: #{why}."
    }
  end
end
