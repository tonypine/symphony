defmodule SymphonyElixir.AcceptanceGate.OpenPrCacheTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AcceptanceGate.OpenPrCache

  setup do
    table = :"open_pr_cache_test_#{System.unique_integer([:positive])}"
    start_supervised!({OpenPrCache, name: table})
    %{table: table}
  end

  test "caches an answer and returns it without asking again", %{table: table} do
    assert {:ok, [:pr]} = OpenPrCache.fetch(table, :key, fn -> {:ok, [:pr]} end)
    assert {:ok, [:pr]} = OpenPrCache.fetch(table, :key, fn -> flunk("asked again") end)
  end

  test "doesn't cache an error", %{table: table} do
    assert {:error, :rate_limited} = OpenPrCache.fetch(table, :key, fn -> {:error, :rate_limited} end)
    assert {:ok, [:pr]} = OpenPrCache.fetch(table, :key, fn -> {:ok, [:pr]} end)
  end

  test "empties a full table before inserting", %{table: table} do
    for n <- 1..256, do: OpenPrCache.fetch(table, n, fn -> {:ok, n} end)
    assert :ets.info(table, :size) == 256

    assert {:ok, :new} = OpenPrCache.fetch(table, :new, fn -> {:ok, :new} end)
    assert :ets.tab2list(table) == [{:new, :new}]
  end

  test "asks every time without its table" do
    assert {:ok, 1} = OpenPrCache.fetch(:open_pr_cache_test_missing, :key, fn -> {:ok, 1} end)
    assert {:ok, 2} = OpenPrCache.fetch(:open_pr_cache_test_missing, :key, fn -> {:ok, 2} end)
  end
end
