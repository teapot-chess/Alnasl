defmodule AlnaslWeb.E2E.BoardsSelectTest do
  @moduledoc """
  The board-of-the-round select stays open while the page re-renders under
  it (2026-11-23, tournament 311: it shut after half a second and the
  choice was lost). LiveView blurs a focused select whose markup changed;
  the select is kept out of the patch, and this is what only a browser
  shows: focus kept, not a node of it touched, and the server's word put in
  once it is let go.
  """
  use AlnaslWeb.E2ECase

  alias Alnasl.{Boards, Settings}

  setup do
    Settings.put("ui_mode", "full")

    document = %{
      "players" => [],
      "rounds" => [
        %{"number" => 1, "boards" => for(n <- 1..3, do: %{"board" => n, "kind" => "game"})}
      ]
    }

    Alnasl.Tournaments.update!(Alnasl.Tournaments.default(), %{document: Jason.encode!(document)})

    [a, b] =
      for {name, game} <- [{"Table A", 1}, {"Table B", 2}] do
        {:ok, board} =
          Boards.create(%{
            name: name,
            driver: "simulator",
            options: %{"game" => game, "speed" => 20}
          })

        board
      end

    Boards.link(a, 1, 1)
    %{a: a, b: b}
  end

  @watch """
  (id) => {
    const sel = document.getElementById(id)
    window.__seen = []
    sel.addEventListener("blur", () => window.__seen.push("blur"))
    new MutationObserver(() => window.__seen.push("patched"))
      .observe(sel, {subtree: true, attributes: true, childList: true})
    sel.focus()
    return document.activeElement.id
  }
  """

  test "an open select is not shut by a re-render, and a choice in it is saved", %{
    conn: conn,
    a: a,
    b: b
  } do
    conn =
      conn
      |> visit("/boards")
      |> assert_has("body .phx-connected")
      |> assert_has("#link-#{a.id}")

    id = "link-#{a.id}"
    evaluate(conn, @watch, [is_function: true, arg: id], &assert(&1 == id))

    # Under the arbiter's hand, board 1 goes to another table: the row's
    # select would have changed, and been blurred.
    Boards.link(Boards.get!(b.id), 1, 1)
    evaluate(conn, "new Promise(r => setTimeout(r, 1500))")

    evaluate(
      conn,
      "({seen: window.__seen, active: document.activeElement.id, box: document.getElementById('#{id}-box').dataset.value})",
      fn state ->
        assert state["seen"] == []
        assert state["active"] == id
        # The server's word is there, waiting.
        assert state["box"] == ""
      end
    )

    # Let go: the select shows what the server says.
    evaluate(conn, "document.getElementById('#{id}').blur()")
    evaluate(conn, "new Promise(r => setTimeout(r, 300))")
    evaluate(conn, "document.getElementById('#{id}').value", &assert(&1 == ""))

    # And a choice made in it is saved.
    conn
    |> select("##{id}", "Board number for Table A", option: "board 2")
    |> then(fn conn ->
      wait_for(fn -> Boards.get!(a.id).board_no == 2 end)
      conn
    end)

    assert %{round: 1, board_no: 2} = Boards.get!(a.id)
  end

  defp wait_for(fun, tries \\ 40) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("not saved")
      true -> Process.sleep(100) && wait_for(fun, tries - 1)
    end
  end
end
