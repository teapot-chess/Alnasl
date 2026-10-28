defmodule AlnaslWeb.E2E.CompactTest do
  @moduledoc """
  The compact layout on the three screens it is for (800x480, 1024x600,
  720x720), in a real browser: `data-compact` is the browser's to set
  (assets/js/theme.js), and where things land is the CSS's and the `.Tour`
  hook's, none of which `Phoenix.LiveViewTest` runs.

  What is measured, not admired: nothing wider than the screen, the tour's
  card and steps inside it and never under the bar at the top, and a game's
  board, clocks and moves in view at once.
  """
  use AlnaslWeb.E2ECase

  alias Alnasl.{Games, Settings, Tournaments}

  setup do
    Settings.put("ui_mode", "full")
    :ok
  end

  # The box of an element, the screen and the top bar, as one map.
  @boxes """
  (selectors) => {
    const box = (s) => {
      const el = document.querySelector(s)
      if (!el) return null
      const r = el.getBoundingClientRect()
      return {top: r.top, bottom: r.bottom, left: r.left, right: r.right}
    }
    const out = {
      compact: document.documentElement.hasAttribute("data-compact"),
      vw: document.documentElement.clientWidth,
      vh: document.documentElement.clientHeight,
      sw: document.documentElement.scrollWidth,
      bar: box("#tab-bar")
    }
    for (const s of selectors) out[s] = box(s)
    return out
  }
  """

  for {w, h} <- [{800, 480}, {1024, 600}, {720, 720}] do
    describe "#{w}x#{h}" do
      @describetag browser_context_opts: [viewport: %{width: w, height: h}]

      test "the tour's card and every step stay on the screen, under the bar", %{conn: conn} do
        conn =
          conn
          |> visit("/")
          |> assert_has("body .phx-connected")
          |> assert_has("#tour-offer")
          |> measure(["#tour-offer"], fn m ->
            assert m["compact"]
            assert_inside(m, "#tour-offer")
          end)
          |> click("#tour-offer-start")

        walk(conn, 1)
      end

      test "Setup, Halls and a game fit the width; the game fits the height", %{conn: conn} do
        tid = Tournaments.default_id()
        Games.ensure(tid, 1, 1, %{})

        for path <- ~w(/setup/wizard /setup/tournaments /setup/connections /setup/updates /halls) do
          conn
          |> visit(path)
          |> assert_has("body .phx-connected")
          |> measure([], fn m ->
            assert m["compact"], path
            assert m["sw"] <= m["vw"], "#{path} is #{m["sw"]} wide on a #{m["vw"]} screen"
          end)
        end

        conn
        |> visit("/round/1/board/1")
        |> assert_has("#position")
        |> measure(["#position", "#moves"], fn m ->
          assert m["sw"] <= m["vw"]
          assert_inside(m, "#position")
          assert_inside(m, "#moves")
        end)
      end
    end
  end

  # Step by step to Done, measuring each popover where it settles.
  defp walk(conn, n) do
    conn =
      conn
      |> assert_has("#tour-pop .tour-pop-count", text: "Step #{n} of")
      |> measure(["#tour-pop"], &assert_inside(&1, "#tour-pop"))

    if has_next?(conn),
      do: conn |> click("#tour-next") |> walk(n + 1),
      else: click(conn, "#tour-done")
  end

  defp has_next?(conn) do
    evaluate(conn, "!!document.querySelector('#tour-next')", &Process.put(:has_next, &1))
    Process.get(:has_next)
  end

  defp measure(conn, selectors, fun) do
    # Placement follows a smooth scroll and a 160 ms slide: let it settle.
    evaluate(conn, "new Promise(r => setTimeout(r, 450))")
    evaluate(conn, @boxes, [is_function: true, arg: selectors], fun)
  end

  defp assert_inside(m, selector) do
    box = m[selector]
    assert box, "#{selector} is not on the page"

    assert box["left"] >= -0.5 and box["right"] <= m["vw"] + 0.5,
           "#{selector} leaves the screen sideways: #{inspect(box)}"

    assert box["bottom"] <= m["vh"] + 0.5, "#{selector} runs off the bottom: #{inspect(box)}"

    assert box["top"] >= m["bar"]["bottom"] - 0.5,
           "#{selector} is under the top bar: #{inspect(box)}"
  end
end
