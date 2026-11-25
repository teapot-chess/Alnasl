defmodule Mix.Tasks.Alnasl.SerialProxyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Alnasl.SerialProxy

  test "a chunk is one line: padded seconds, direction, hex bytes" do
    assert SerialProxy.chunk_line(12.345678, SerialProxy.tag(:app), <<0x42>>) ==
             "   12.345678  APP>BRD  42\n"

    assert SerialProxy.chunk_line(0.1, SerialProxy.tag(:board), <<0x86, 0, 0x43>>) ==
             "    0.100000  BRD>APP  86 00 43\n"
  end

  test "a note is a comment line the replay skips" do
    assert SerialProxy.note_line(5.0, "b1 e2e4") == "#     5.000000  NOTE  b1 e2e4\n"
  end
end
