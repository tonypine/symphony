defmodule SymphonyElixir.QaAndroid.UiTreeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaAndroid.UiTree

  defp hierarchy(nodes), do: ~s(<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="1">#{nodes}</hierarchy>)

  defp nodes(nodes) do
    {:ok, entries} = UiTree.parse(hierarchy(nodes))
    Enum.map(entries, fn {_depth, _package, node} -> node end)
  end

  test "decodes XML entities, and keeps an invalid character reference as it is" do
    [node] = nodes(~s(<node text="&lt;b&gt; &amp; &apos;x&apos; &#x1F600; &#233; &#xD800; &#1114112; &amp;lt;" class="V" />))
    assert node["text"] == "<b> & 'x' 😀 é &#xD800; &#1114112; &lt;"
  end

  test "numbers children by position and survives unbalanced closing tags" do
    entries = nodes(~s(</node><node class="A"><node class="B" /><node class="C"></node></node></node><node class="D"/>))
    assert Enum.map(entries, &{&1["path"], &1["class"]}) == [{"0", "A"}, {"0.0", "B"}, {"0.1", "C"}, {"1", "D"}]
  end

  test "leaves out bounds it cannot read and attributes that are missing" do
    [bad, missing] = nodes(~s(<node bounds="[0,0][10]" /><node>))
    assert bad == %{"path" => "0", "class" => "", "bounds" => nil, "clickable" => false, "focused" => false, "enabled" => false, "checked" => false, "scrollable" => false}
    assert missing["bounds"] == nil
    assert {:ok, [{1, nil, _node}, {1, nil, _other}]} = UiTree.parse(hierarchy(~s(<node /><node />)))
  end

  test "returns :error without a hierarchy" do
    assert UiTree.parse("ERROR: null root node returned by UiTestAutomationBridge.") == :error
  end

  test "selects with no cap reached" do
    {:ok, entries} = UiTree.parse(hierarchy(~s(<node class="android.widget.Button" text="OK" />)))
    assert {[%{"text" => "OK"}], []} = UiTree.select(entries, %{}, 1, 1, 1_000)
    assert {[], ["1 more nodes over the 10-byte limit"]} = UiTree.select(entries, %{class: "Button"}, 1, 1, 10)
  end
end
