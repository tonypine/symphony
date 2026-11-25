defmodule SymphonyElixir.QaDriver.ElementsTest do
  # TP-1677: the app's element report, read for qa_elements, qa_scroll_to, qa_measure_elements and the
  # app state qa_check_app and qa_wait_check return.
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaDriver.{Elements, Host}

  @window %{"number" => 7, "title" => "Symphony", "frame" => %{"x" => 0, "y" => 25, "w" => 1000, "h" => 500}, "key" => true}

  defp element(name, y, opts \\ []) do
    base = %{
      "name" => name,
      "frame" => %{"x" => Keyword.get(opts, :x, 100), "y" => y, "w" => Keyword.get(opts, :w, 800), "h" => Keyword.get(opts, :h, 32)},
      "visible" => Keyword.get(opts, :visible, true),
      "window" => 7,
      "selected" => Keyword.get(opts, :selected, false),
      "focused" => false,
      "parts" => Keyword.get(opts, :parts, %{})
    }

    case Keyword.fetch(opts, :shown) do
      {:ok, {shown_y, shown_h}} ->
        Map.merge(base, %{"fully_visible" => false, "shown" => %{"x" => base["frame"]["x"], "y" => shown_y, "w" => base["frame"]["w"], "h" => shown_h}})

      :error ->
        base
    end
  end

  defp report(elements, opts \\ []) do
    %{
      "version" => 1,
      "at" => Keyword.get(opts, :at, "2026-11-25T15:00:00Z"),
      "pid" => 42,
      "windows" => Keyword.get(opts, :windows, [@window]),
      "state" => %{"page" => "overview", "page_title" => "Home", "ticket" => nil, "selected" => ["sidebar-home"], "focused" => []},
      "elements" => elements,
      "names" => [%{"pattern" => "queue-row-<ticket>", "what" => "A row of Home's queue", "parts" => ["identifier", "title"]}]
    }
  end

  describe "read/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "qa-elements-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([dir, "app-root", "elements"]))
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir, qa_root: Path.join(dir, "app-root")}
    end

    defp config(dir, overrides \\ %{}) do
      host = %{
        cmd: Map.get(overrides, :cmd, &Host.cmd/3),
        # As `Remote.read/2`: the copy is taken away once read.
        read:
          Map.get(overrides, :read, fn path ->
            bytes = File.read!(path)
            File.rm!(path)
            {:ok, bytes}
          end)
      }

      %{host_dir: dir, host: host}
    end

    test "copies the app's report aside in the run directory and reads the copy, leaving the app's", %{dir: dir, qa_root: qa_root} do
      written = report([element("queue-row-TP-1", 100)])
      path = Path.join([qa_root, "elements", "42.json"])
      File.write!(path, Jason.encode!(written))

      assert Elements.read(config(dir), qa_root, 42) == {:ok, written}
      assert File.exists?(path)
      assert Path.wildcard(Path.join(dir, "elements-*.json")) == []
    end

    test "names an app that wrote no report, or one it cannot read", %{dir: dir, qa_root: qa_root} do
      assert {:error, {:qa_tool, "qa_elements_missing", message}} = Elements.read(config(dir), qa_root, 42)
      assert message =~ "a release build, or one from before QA element names"
      assert message =~ "qa_ax_tree"

      path = Path.join([qa_root, "elements", "42.json"])
      unreadable = fn -> elem(Elements.read(config(dir), qa_root, 42), 1) end

      File.write!(path, Jason.encode!(%{"version" => 2, "elements" => []}))
      assert {:qa_tool, "qa_elements_unreadable", message} = unreadable.()
      assert message =~ "it is version 2; this driver reads version 1"

      File.write!(path, "{not json")
      assert {:qa_tool, "qa_elements_unreadable", message} = unreadable.()
      assert message =~ "it is not the app's JSON report"

      File.write!(path, Jason.encode!(report([])))
      assert {:error, {:qa_tool, "qa_elements_unreadable", message}} = Elements.read(config(dir, %{read: fn _path -> {:error, :unreadable} end}), qa_root, 42)
      assert message =~ ":unreadable"

      for {reply, expected} <- [
            {{:ok, {"something else\n", 0}}, ~s(the copy said "something else")},
            {{:ok, {"cp: denied\n", 1}}, "the copy failed (exit 1): cp: denied"},
            {{:error, :timeout}, ":timeout"}
          ] do
        cmd = fn "/bin/sh", ["-c", _script, "sh", ^qa_root, "42", _taken], _opts -> reply end
        assert {:error, {:qa_tool, "qa_elements_unreadable", message}} = Elements.read(config(dir, %{cmd: cmd}), qa_root, 42)
        assert message =~ expected
      end
    end
  end

  test "lists the elements by prefix and visibility, with the state, windows and naming scheme" do
    rows = [element("queue-row-TP-1", 100), element("queue-row-TP-2", 600, visible: false), element("sidebar-home", 40, selected: true)]
    report = report(rows ++ ["not an element", %{"frame" => %{}}])

    listing = Elements.listing(report, nil, false)
    assert Enum.map(listing["elements"], & &1["name"]) == ["queue-row-TP-1", "queue-row-TP-2", "sidebar-home"]
    assert listing["count"] == 3
    assert listing["windows"] == [@window]
    assert listing["state"] == %{"page" => "overview", "page_title" => "Home", "ticket" => nil, "selected" => ["sidebar-home"], "focused" => [], "at" => "2026-11-25T15:00:00Z"}
    assert [%{"pattern" => "queue-row-<ticket>"}] = listing["names"]
    assert listing["at"] == "2026-11-25T15:00:00Z"

    assert %{"count" => 2} = Elements.listing(report, "queue-row-", false)
    assert %{"elements" => [%{"name" => "queue-row-TP-1"}], "count" => 1} = Elements.listing(report, "queue-row-", true)
    assert %{"windows" => [], "names" => [], "count" => 0} = Elements.listing(%{"elements" => [], "at" => nil}, nil, false)
  end

  test "gives the app's state for qa_check_app, or why there is none" do
    assert %{"app_state" => %{"page" => "overview", "at" => "2026-11-25T15:00:00Z"}} = Elements.state_fields({:ok, report([])})

    assert Elements.state_fields({:error, {:qa_tool, "qa_elements_missing", "none"}}) == %{"app_state" => nil, "app_state_note" => "none"}
  end

  describe "measure/4" do
    @title %{"x" => 180, "y" => 108, "w" => 300, "h" => 16}

    test "gives offsets, alignment, gaps, size and distance from the reported frames" do
      report = report([element("queue-row-TP-1", 100, parts: %{"title" => @title}), element("queue-row-TP-2", 140, x: 100, w: 600)])

      assert {:ok, result} = Elements.measure(report, "queue-row-TP-1", "queue-row-TP-2", 0.5)
      assert result["a"] == %{"name" => "queue-row-TP-1", "frame" => %{"x" => 100, "y" => 100, "w" => 800, "h" => 32}}
      assert result["offsets"] == %{"left" => 0.0, "right" => -200.0, "top" => 40.0, "bottom" => 40.0, "center_x" => -100.0, "center_y" => 40.0}
      assert result["aligned"] == ["left"]
      assert result["gap"] == %{"x" => -600.0, "y" => 8.0}
      assert result["size"] == %{"w" => -200.0, "h" => 0.0}
      assert result["distance"] == 107.7
      assert result["within"] == 0.5
      assert result["at"] == "2026-11-25T15:00:00Z"

      # A part, by `name:part`: the title's centre sits on the row's.
      assert {:ok, %{"b" => %{"name" => "queue-row-TP-1:title", "frame" => @title}, "aligned" => aligned}} =
               Elements.measure(report, "queue-row-TP-1", "queue-row-TP-1:title", 0.5)

      assert aligned == ["center_y"]
    end

    test "names an element or a part the report lacks" do
      report = report([element("queue-row-TP-1", 100, parts: %{"title" => @title, "identifier" => @title}), element("sidebar-home", 40)])

      assert {:error, {:qa_tool, "qa_element_not_found", message}} = Elements.measure(report, "queue-row-TP-9", "sidebar-home", 1)
      assert message =~ "No element named queue-row-TP-9 is on screen"

      assert {:error, {:qa_tool, "qa_element_not_found", message}} = Elements.measure(report, "sidebar-home", "queue-row-TP-1:repo", 1)
      assert message == "queue-row-TP-1 has no part repo; its parts are identifier, title."

      assert {:error, {:qa_tool, "qa_element_not_found", message}} = Elements.measure(report, "sidebar-home:title", "sidebar-home", 1)
      assert message == "sidebar-home has no part title; its parts are none."

      broken = report([%{"name" => "bad", "frame" => %{"x" => 1}}, element("sidebar-home", 40)])
      assert {:error, {:qa_tool, "qa_elements_unreadable", message}} = Elements.measure(broken, "sidebar-home", "bad", 1)
      assert message =~ "bad's frame is not x, y, w and h"
    end

    test "checks its arguments" do
      assert Elements.measure_arguments(%{"a" => "x", "b" => "y"}) == {:ok, {"x", "y", 0.5}}
      assert Elements.measure_arguments(%{"a" => "x", "b" => "y", "within" => 2}) == {:ok, {"x", "y", 2}}

      bad_within = [%{"a" => "x", "b" => "y", "within" => -1}, %{"a" => "x", "b" => "y", "within" => "1"}]

      for args <- [%{"b" => "y"}, %{"a" => "", "b" => "y"}, %{"a" => "x"} | bad_within] do
        assert {:error, {:qa_tool, "invalid_arguments", _message}} = Elements.measure_arguments(args)
      end
    end
  end

  describe "scroll_to/4" do
    defp io(reports, answers \\ []) do
      test = self()
      {:ok, agent} = Agent.start_link(fn -> {reports, answers} end)

      read = fn ->
        Agent.get_and_update(agent, fn
          {[only], answers} -> {only, {[only], answers}}
          {[next | rest], answers} -> {next, {rest, answers}}
        end)
      end

      scroll = fn point, dy ->
        send(test, {:scrolled, point, dy})

        Agent.get_and_update(agent, fn
          {reports, [answer | rest]} -> {answer, {reports, rest}}
          {reports, []} -> {{:ok, %{"ok" => true}}, {reports, []}}
        end)
      end

      sleep = fn ms -> send(test, {:slept, ms}) end
      {read, scroll, sleep}
    end

    defp request(name, opts \\ []), do: Map.merge(%{name: name, at: nil, direction: nil, max_scrolls: 20}, Map.new(opts))

    defp scroll_to(request, reports, answers \\ []) do
      {read, scroll, sleep} = io(Enum.map(reports, &wrap/1), answers)
      Elements.scroll_to(request, read, scroll, sleep)
    end

    defp wrap(%{} = report), do: {:ok, report}
    defp wrap(error), do: error

    test "answers at once for an element already shown" do
      assert {:ok, %{"name" => "done-row-TP-1", "scrolls" => 0, "state" => %{"page" => "overview"}}} =
               scroll_to(request("done-row-TP-1"), [report([element("done-row-TP-1", 100)])])

      refute_received {:scrolled, _point, _dy}
    end

    test "scrolls toward an element the report has but does not show, as far as it is" do
      below = report([element("done-row-TP-1", 700, visible: false)])
      above = report([element("done-row-TP-1", -100, visible: false)])
      shown = report([element("done-row-TP-1", 300)])

      answers = [{:ok, %{"moved" => %{"y" => 300}}}]
      assert {:ok, %{"scrolls" => 1, "frame" => %{"y" => 300}}} = scroll_to(request("done-row-TP-1"), [below, shown], answers)
      # The window spans 25 to 525: the row's bottom (732) is 207 below, plus a margin.
      assert_received {:scrolled, "500,275", 247}
      assert_received {:slept, 400}

      assert {:ok, %{"scrolls" => 1}} = scroll_to(request("done-row-TP-1"), [above, shown])
      assert_received {:scrolled, "500,275", -165}

      # Clipped by its list while inside the window: a page in the direction searched.
      clipped = report([element("done-row-TP-1", 400, visible: false)])
      assert {:ok, %{"scrolls" => 1}} = scroll_to(request("done-row-TP-1", direction: "up"), [clipped, shown])
      assert_received {:scrolled, "500,275", -300}
    end

    test "goes on scrolling while a row is only partly shown, toward its cut edge" do
      # Its bottom 7 points are cut by the list: down past them, by the least scroll.
      cut_below = report([element("done-row-TP-1", 500, shown: {500, 25})])
      whole = report([element("done-row-TP-1", 460)])
      answers = [{:ok, %{"moved" => %{"y" => 40}}}]
      assert {:ok, %{"scrolls" => 1, "frame" => %{"y" => 460}} = found} = scroll_to(request("done-row-TP-1"), [cut_below, whole], answers)
      refute Map.has_key?(found, "partly_shown")
      assert_received {:scrolled, "500,275", 40}

      # Its top is cut: up.
      cut_above = report([element("done-row-TP-1", 10, shown: {25, 17})])
      assert {:ok, %{"scrolls" => 1}} = scroll_to(request("done-row-TP-1"), [cut_above, whole], answers)
      assert_received {:scrolled, "500,275", -40}

      # Not wholly shown, with no edge cut that the report says: a page in the direction searched.
      odd = report([element("done-row-TP-1", 100, shown: {100, 32})])
      assert {:ok, %{"scrolls" => 1}} = scroll_to(request("done-row-TP-1"), [odd, whole], answers)
      assert_received {:scrolled, "500,275", 300}
    end

    test "returns a row taller than the list as partly shown once the list stops, or the scrolls run out" do
      tall = report([element("done-row-TP-1", 25, h: 900, shown: {25, 500})])
      stopped = [{:ok, %{"moved" => %{"y" => 0}}}]

      assert {:ok, %{"name" => "done-row-TP-1", "scrolls" => 1, "partly_shown" => note}} =
               scroll_to(request("done-row-TP-1"), [tall], stopped)

      assert note =~ "Only part of done-row-TP-1 shows (`shown`) once the list stopped moving (1 scrolls)"
      assert_received {:scrolled, "500,275", 300}

      lower = report([element("done-row-TP-1", -275, h: 900, shown: {25, 500})])
      moving = [{:ok, %{"moved" => %{"y" => 300}}}]

      assert {:ok, %{"scrolls" => 1, "partly_shown" => note}} =
               scroll_to(request("done-row-TP-1", max_scrolls: 1), [tall, lower], moving)

      assert note =~ "after 1 scrolls"
    end

    test "looks down, then up, for a row a lazy list has not drawn" do
      first = report([element("done-row-TP-1", 100)])
      later = report([element("done-row-TP-2", 100)])
      found = report([element("done-row-TP-9", 200)])

      # Down a page at a time while the list moves; it turns up once it stops.
      answers = [{:ok, %{"moved" => %{"y" => 300}}}, {:ok, %{"moved" => %{"y" => 0}}}]

      assert {:ok, %{"name" => "done-row-TP-9", "scrolls" => 3}} =
               scroll_to(request("done-row-TP-9"), [first, later, later, found], answers)

      assert_received {:scrolled, _point, 300}
      assert_received {:scrolled, _point, 300}
      assert_received {:scrolled, _point, -300}
    end

    test "gives up when the list stops moving, or after max_scrolls" do
      first = report([element("done-row-TP-1", 100)])

      # No `moved` in the helper's answer: an unchanged report says the list did not move.
      assert {:error, {:qa_tool, "qa_element_not_found", message}} = scroll_to(request("done-row-TP-9"), [first])
      assert message =~ "done-row-TP-9 did not come into view once the list stopped moving (2 scrolls)"
      assert message =~ "Check the name with qa_elements"

      # A named direction does not turn.
      assert {:error, {:qa_tool, "qa_element_not_found", message}} = scroll_to(request("done-row-TP-9", direction: "down"), [first])
      assert message =~ "(1 scrolls)"

      # A report that changes means the list moved.
      moving = for y <- 1..5, do: report([element("done-row-TP-#{y}", 100 + y)])
      assert {:error, {:qa_tool, "qa_element_not_found", message}} = scroll_to(request("done-row-TP-9", max_scrolls: 3), moving)
      assert message =~ "after 3 scrolls"
    end

    test "scrolls at a shown element of the list when the call names one" do
      first = report([element("done-row-TP-1", 100, x: 40, w: 200), element("done-row-TP-2", 900, visible: false)])
      reports = [first, report([element("done-row-TP-2", 300)])]
      assert {:ok, %{"scrolls" => 1}} = scroll_to(request("done-row-TP-2", at: "done-row-TP-1"), reports)
      assert_received {:scrolled, "140,116", _dy}

      assert {:error, {:qa_tool, "qa_element_not_found", message}} = scroll_to(request("done-row-TP-2", at: "done-row-TP-2"), reports)
      assert message =~ "done-row-TP-2 is not shown, so it cannot be scrolled at"

      # Without windows in the report: a default page, and the element is scrolled toward from the screen's top.
      bare = report([element("done-row-TP-1", 100, x: 40, w: 200), element("done-row-TP-2", 900, visible: false)], windows: [])
      assert {:ok, _found} = scroll_to(request("done-row-TP-2", at: "done-row-TP-1"), [bare, report([element("done-row-TP-2", 300)])])
      assert_received {:scrolled, "140,116", 400}

      assert {:error, {:qa_tool, "qa_element_not_found", message}} = scroll_to(request("done-row-TP-2"), [bare])
      assert message =~ "The app reports no window with named elements"
    end

    test "passes on a report or a scroll that fails" do
      missing = {:error, {:qa_tool, "qa_elements_missing", "none"}}
      assert scroll_to(request("x"), [missing]) == missing

      hidden = report([element("done-row-TP-1", 900, visible: false)])
      covered = {:error, {:qa_tool, "qa_covered", "Dock"}}
      assert scroll_to(request("done-row-TP-1"), [hidden], [covered]) == covered
      assert scroll_to(request("done-row-TP-1"), [hidden, missing]) == missing
    end

    test "checks its arguments" do
      assert Elements.scroll_arguments(%{"name" => "done-row-TP-1"}) == {:ok, %{name: "done-row-TP-1", at: nil, direction: nil, max_scrolls: 20}}

      assert Elements.scroll_arguments(%{"name" => "a", "at" => "b", "direction" => "up", "max_scrolls" => 5}) ==
               {:ok, %{name: "a", at: "b", direction: "up", max_scrolls: 5}}

      for args <- [%{}, %{"name" => "a", "at" => 1}, %{"name" => "a", "direction" => "left"}, %{"name" => "a", "max_scrolls" => 51}] do
        assert {:error, {:qa_tool, "invalid_arguments", _message}} = Elements.scroll_arguments(args)
      end
    end
  end

  test "names the folder the app writes its report into" do
    assert Elements.folder() == "elements"
  end
end
