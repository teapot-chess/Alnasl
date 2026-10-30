defmodule Alnasl.SecretCodeTest do
  use ExUnit.Case, async: true

  alias Alnasl.SecretCode

  test "only characters of the alphabet, as many as asked, and all of them in time" do
    alphabet = ~c"23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    drawn = SecretCode.chars(alphabet, 5_000)

    assert length(drawn) == 5_000
    assert Enum.all?(drawn, &(&1 in alphabet))
    assert drawn |> Enum.uniq() |> length() == length(alphabet)
  end

  test "no character is favoured: each of 31 near its share of 31,000" do
    counts = ~c"23456789ABCDEFGHJKMNPQRSTUVWXYZ" |> SecretCode.chars(31_000) |> Enum.frequencies()
    # Without rejection the first 8 characters would get 9/8 of the rest.
    assert Enum.all?(Map.values(counts), &(&1 in 800..1_200))
  end
end
