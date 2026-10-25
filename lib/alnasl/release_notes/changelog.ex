defmodule Alnasl.ReleaseNotes.Changelog do
  @moduledoc false
  # Its own module because `Alnasl.ReleaseNotes` reads the file at compile
  # time, and a module cannot call its own functions while it is compiling.

  @heading ~r/^## \[(\d+\.\d+\.\d+[^\]]*)\](?:\s*-\s*(\S+))?\s*$/m

  @doc """
  CHANGELOG text to `[%{version, date, body}]`. `[Unreleased]` is left out:
  it has no version to be compared with.
  """
  def parse(text) when is_binary(text) do
    heads = Regex.scan(@heading, text, return: :index)

    heads
    |> Enum.with_index()
    |> Enum.map(fn {[{start, len}, {v_at, v_len} | date], i} ->
      stop =
        case Enum.at(heads, i + 1) do
          [{next, _len} | _] -> next
          nil -> byte_size(text)
        end

      %{
        version: binary_part(text, v_at, v_len),
        date:
          case date do
            [{d_at, d_len}] -> binary_part(text, d_at, d_len)
            _none -> nil
          end,
        body: text |> binary_part(start + len, stop - start - len) |> String.trim()
      }
    end)
  end
end
