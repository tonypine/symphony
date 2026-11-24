defmodule SymphonyElixir.Dispatch.SortKeyTest do
  # The reference fractional indexing algorithm's published test cases (rocicorp/fractional-indexing,
  # `src/index.test.js`, base 62).
  use ExUnit.Case, async: true

  alias SymphonyElixir.Dispatch.SortKey

  @between [
    {nil, nil, "a0"},
    {nil, "a0", "Zz"},
    {nil, "Zz", "Zy"},
    {"a0", nil, "a1"},
    {"a1", nil, "a2"},
    {"a0", "a1", "a0V"},
    {"a1", "a2", "a1V"},
    {"a0V", "a1", "a0l"},
    {"Zz", "a0", "ZzV"},
    {"Zz", "a1", "a0"},
    {nil, "Y00", "Xzzz"},
    {"bzz", nil, "c000"},
    {"a0", "a0V", "a0G"},
    {"a0", "a0G", "a08"},
    {"b125", "b129", "b127"},
    {"a0", "a1V", "a1"},
    {"Zz", "a01", "a0"},
    {nil, "a0V", "a0"},
    {nil, "b999", "b99"},
    {nil, "A000000000000000000000000001", "A000000000000000000000000000V"},
    {"zzzzzzzzzzzzzzzzzzzzzzzzzzy", nil, "zzzzzzzzzzzzzzzzzzzzzzzzzzz"},
    {"zzzzzzzzzzzzzzzzzzzzzzzzzzz", nil, "zzzzzzzzzzzzzzzzzzzzzzzzzzzV"}
  ]

  @errors [
    {nil, "A00000000000000000000000000", "invalid order key: A00000000000000000000000000"},
    {"a00", nil, "invalid order key: a00"},
    {"a00", "a1", "invalid order key: a00"},
    {"0", "1", "invalid order key head: 0"},
    {"a1", "a0", "a1 >= a0"}
  ]

  @n_between [
    {nil, nil, 5, "a0 a1 a2 a3 a4"},
    {"a4", nil, 10, "a5 a6 a7 a8 a9 aA aB aC aD aE"},
    {nil, "a0", 5, "Zv Zw Zx Zy Zz"},
    {"a0", "a2", 20, "a04 a08 a0G a0K a0O a0V a0Z a0d a0l a0t a1 a14 a18 a1G a1O a1V a1Z a1d a1l a1t"}
  ]

  test "key_between/2 gives the reference's keys" do
    for {a, b, expected} <- @between do
      assert SortKey.key_between(a, b) == {:ok, expected}, "between #{inspect(a)} and #{inspect(b)}"
    end
  end

  test "key_between/2 refuses what the reference refuses, with its message" do
    for {a, b, message} <- @errors do
      assert SortKey.key_between(a, b) == {:error, message}, "between #{inspect(a)} and #{inspect(b)}"
    end
  end

  test "n_keys_between/3 gives the reference's evenly spaced keys" do
    for {a, b, n, expected} <- @n_between do
      assert SortKey.n_keys_between(a, b, n) == {:ok, String.split(expected)}
    end

    assert SortKey.n_keys_between("a0", "a1", 0) == {:ok, []}
    assert SortKey.n_keys_between("a1", "a0", 3) == {:error, "a1 >= a0"}
  end

  test "the keys sort by plain comparison, in the order they were asked for" do
    {:ok, keys} = SortKey.n_keys_between(nil, nil, 100)
    assert Enum.sort(keys) == keys
    assert Enum.uniq(keys) == keys
  end

  test "keys at the integer part's ends and across a change of its length, and malformed keys" do
    assert SortKey.key_between(nil, "A000000000000000000000000000V") == {:ok, "A000000000000000000000000000G"}
    assert SortKey.key_between("zzzzzzzzzzzzzzzzzzzzzzzzzzz", "zzzzzzzzzzzzzzzzzzzzzzzzzzzV") == {:ok, "zzzzzzzzzzzzzzzzzzzzzzzzzzzG"}
    assert SortKey.key_between("a0", "b00") == {:ok, "a1"}
    assert SortKey.key_between("az", "b00") == {:ok, "azV"}
    assert SortKey.key_between("Zz", "a0V") == {:ok, "a0"}
    assert SortKey.key_between(nil, "B0") == {:error, "invalid order key: B0"}
    assert SortKey.key_between(nil, "b00") == {:ok, "az"}
    assert SortKey.key_between("a01", "a02V") == {:ok, "a02"}
    assert SortKey.key_between("Yzz", nil) == {:ok, "Z0"}
    assert SortKey.key_between("a!", nil) == {:error, "invalid order key digit: !"}
    assert SortKey.key_between("", nil) == {:error, "invalid order key: "}
  end

  test "valid?/1" do
    assert SortKey.valid?("a0")
    assert SortKey.valid?("a0V")
    refute SortKey.valid?("a00")
    refute SortKey.valid?("")
    refute SortKey.valid?("0")
    refute SortKey.valid?(nil)
    refute SortKey.valid?(3)
  end
end
