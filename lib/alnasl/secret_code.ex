defmodule Alnasl.SecretCode do
  @moduledoc """
  Characters for things that open doors - join codes, pairing codes,
  temporary passwords - drawn from `:crypto.strong_rand_bytes/1`.

  `Enum.random/1` draws from `:rand`, which is quick, fair and entirely
  willing to be predicted. Each character here comes from one random byte;
  a byte past the last whole multiple of the alphabet's length is thrown
  away and another drawn (rejection sampling), so no character turns up
  more often than its neighbours.
  """

  @doc "`count` characters of `alphabet` (a charlist of at most 256), as a charlist."
  @spec chars(charlist(), pos_integer()) :: charlist()
  def chars(alphabet, count)
      when is_list(alphabet) and length(alphabet) in 1..256 and is_integer(count) and count > 0 do
    size = length(alphabet)
    table = List.to_tuple(alphabet)
    limit = 256 - rem(256, size)
    draw(table, size, limit, count, [])
  end

  defp draw(_table, _size, _limit, 0, acc), do: acc

  defp draw(table, size, limit, count, acc) do
    <<byte>> = :crypto.strong_rand_bytes(1)

    if byte < limit,
      do: draw(table, size, limit, count - 1, [elem(table, rem(byte, size)) | acc]),
      else: draw(table, size, limit, count, acc)
  end
end
