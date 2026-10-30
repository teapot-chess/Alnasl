defmodule AlnaslWeb.Compact480CssTest do
  use ExUnit.Case, async: true

  @css File.read!(Path.expand("../../assets/css/app.css", __DIR__))

  test "the 3.5 inch layout sits behind media queries, under the compact attribute" do
    [_, block] = String.split(@css, "==== compact-480:", parts: 2)
    [block, _] = String.split(block, "==== end compact-480 ====", parts: 2)

    assert block =~ "@media (max-width: 520px), (max-height: 360px)"
    assert block =~ "@media (max-width: 520px) and (max-aspect-ratio: 4/3)"
    assert block =~ "@media (max-width: 400px)"
    assert block =~ ".play-board"
    assert block =~ ".choice-arrows"
    assert block =~ "min-height: 2.75rem"
    # nothing in the block applies outside the compact layout
    rules = Regex.scan(~r/^  (:root[^\n{]*|\.[^\n{]*)\{/m, block)
    assert Enum.all?(rules, fn [line, _] -> String.contains?(line, ":root[data-compact]") end)
  end

  test "the Pages table is cards, and the tab bar names its tabs without their words" do
    pgn = File.read!(Path.expand("../../lib/alnasl_web/live/pgn_live.ex", __DIR__))
    layouts = File.read!(Path.expand("../../lib/alnasl_web/components/layouts.ex", __DIR__))
    assert pgn =~ ~s(id="stored-games" class="cards")
    assert layouts =~ "aria-label={tab.label}"
  end
end
