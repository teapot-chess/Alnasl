defmodule AlnaslWeb.NumberingTest do
  @moduledoc """
  Two DGT boards on the Boards page, numbered one after the other by hand:
  board A table 1, then board B table 2. Nothing else may move - not the
  other board's number, not its board of the round, and not the rows on the
  page either, or the arbiter's next tap lands on the wrong board.
  """

  use AlnaslWeb.SiteCase

  @moduletag :capture_log

  alias Alnasl.{Finder, Tables, Tournaments}
  alias Arkab.Dgt.Emulator
  alias Arkab.Transport.Fake

  setup do
    Finder.reset()
    on_exit(fn -> Finder.reset() end)
    :ok
  end

  defp device(port, serial) do
    start_supervised!(
      {Fake, port: port, device: {Emulator, Emulator.new(serial: serial)}},
      id: port
    )
  end

  defp dgt(port, serial, attrs \\ %{}) do
    device(port, serial)

    {:ok, board} =
      Boards.create(Map.merge(%{name: "DGT " <> port, driver: "dgt_serial", port: port}, attrs))

    eventually(fn -> Boards.get!(board.id).serial == serial end)
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    Boards.get!(board.id)
  end

  defp slot(board) do
    row = Boards.get!(board.id)
    {row.table_no, row.round, row.board_no}
  end

  # The board rows in the order the page shows them.
  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#board-list tbody tr[id^='board-']")
    |> LazyHTML.attribute("id")
  end

  defp number(view, board, table) do
    view |> form("#table-form-#{board.id}", %{table_no: to_string(table)}) |> render_change()
  end

  describe "the ways to number, on the Boards page" do
    test "touching, in order and by hand are side by side; touching opens the run",
         %{conn: conn} do
      a = dgt("FAKE-A", "10001")
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#numbering #number-by-touch", "Number boards by touching them")
      assert has_element?(view, "#numbering #link-in-order-form")
      assert has_element?(view, "#numbering #numbering-by-hand")
      # "Show me" finds a board; it is not one of the ways to number.
      refute has_element?(view, "#numbering #show-me-#{a.id}")

      assert {:error, {:live_redirect, %{to: "/boards/number"}}} =
               view |> element("#number-by-touch") |> render_click()

      {:ok, run, _html} = live(conn, ~p"/boards/number")
      run |> form("#walk-start-form", walk: %{first: "1"}) |> render_submit()
      Finder.touch(a.id)
      eventually(fn -> Boards.get!(a.id).table_no == 1 end)
    end
  end

  describe "numbering two boards one after the other" do
    test "A then B: each keeps its number, and the rows stay where they were", %{conn: conn} do
      a = dgt("FAKE-A", "10001")
      b = dgt("FAKE-B", "10002")
      {:ok, view, _html} = live(conn, ~p"/boards")
      order = rows(view)

      number(view, a, 1)
      assert slot(a) == {1, 1, 1}
      assert slot(b) == {nil, nil, nil}
      assert rows(view) == order

      number(view, b, 2)
      assert slot(a) == {1, 1, 1}
      assert slot(b) == {2, 1, 2}
      assert rows(view) == order
    end

    test "B then A: the same", %{conn: conn} do
      a = dgt("FAKE-A", "10001")
      b = dgt("FAKE-B", "10002")
      {:ok, view, _html} = live(conn, ~p"/boards")
      order = rows(view)

      number(view, b, 2)
      assert slot(b) == {2, 1, 2}
      assert slot(a) == {nil, nil, nil}
      assert rows(view) == order

      number(view, a, 1)
      assert {slot(a), slot(b)} == {{1, 1, 1}, {2, 1, 2}}
      assert rows(view) == order
    end

    test "with boards of the round set already, the other way round", %{conn: conn} do
      a = dgt("FAKE-A", "10001")
      b = dgt("FAKE-B", "10002")
      Boards.link(Boards.get!(b.id), 1, 1)
      Boards.link(Boards.get!(a.id), 1, 2)
      {:ok, view, _html} = live(conn, ~p"/boards")
      order = rows(view)

      # Table 1 is board 1, which B fed: said, not done behind anyone's back.
      number(view, a, 1)
      assert slot(a) == {1, 1, 1}
      assert slot(b) == {nil, nil, nil}
      assert has_element?(view, "#flash-info", "\"DGT FAKE-B\" no longer feeds board 1")
      assert rows(view) == order

      number(view, b, 2)
      assert {slot(a), slot(b)} == {{1, 1, 1}, {2, 1, 2}}
      assert rows(view) == order
    end

    test "in a tournament with a range of tables", %{conn: conn} do
      a = dgt("FAKE-A", "10001")
      b = dgt("FAKE-B", "10002")
      {:ok, _} = Tournaments.assign_tables(Tournaments.default(), 5, 8)
      {:ok, view, _html} = live(conn, ~p"/boards")
      order = rows(view)

      number(view, a, 5)
      assert slot(a) == {5, 1, 1}
      assert slot(b) == {nil, nil, nil}

      number(view, b, 6)
      assert {slot(a), slot(b)} == {{5, 1, 1}, {6, 1, 2}}
      assert rows(view) == order
    end

    test "a board replugged a moment ago: the numbers survive the rows becoming one",
         %{conn: conn} do
      a = dgt("FAKE-A", "10001")
      b = dgt("FAKE-B", "10002")

      # A goes into another hub before its old port noticed.
      device("FAKE-A2", "10001")
      {:ok, again} = Boards.create(%{name: "Board new", driver: "dgt_serial", port: "FAKE-A2"})
      eventually(fn -> Boards.get!(again.id).serial == "10001" end)
      eventually(fn -> Boards.snapshot(again.id).connected? end)

      {:ok, view, _html} = live(conn, ~p"/boards")
      number(view, again, 1)
      number(view, b, 2)
      assert slot(b) == {2, 1, 2}

      # And now the old port has.
      stop_supervised!("FAKE-A")

      row =
        eventually(fn ->
          case Enum.filter(Boards.list(), &(&1.serial == "10001")) do
            [row] -> row
            _two -> nil
          end
        end)

      assert {row.table_no, row.round, row.board_no} == {1, 1, 1}
      assert row.id in [a.id, again.id]
      assert slot(b) == {2, 1, 2}
    end

    # The board was known as table 3 by its serial: it stays table 3 (the
    # sticker on it says so), and the 1 typed on the row that went is said
    # in the log, not lost without a word.
    test "a number on the replugged row that went is said in the log" do
      a = dgt("FAKE-A", "10001")
      {:ok, _} = Tables.set_table(a, 3)

      device("FAKE-A2", "10001")
      {:ok, again} = Boards.create(%{name: "Board new", driver: "dgt_serial", port: "FAKE-A2"})
      eventually(fn -> Boards.get!(again.id).serial == "10001" end)
      eventually(fn -> Boards.snapshot(again.id).connected? end)

      # The arbiter takes the new row for a new board and numbers it.
      {:ok, _} = Tables.set_table(Boards.get!(again.id), 1)
      stop_supervised!("FAKE-A")

      row =
        eventually(fn ->
          case Enum.filter(Boards.list(), &(&1.serial == "10001")) do
            [row] -> row
            _two -> nil
          end
        end)

      assert {row.id, row.table_no, row.board_no} == {a.id, 3, 3}
      eventually(fn -> "table.merged" in log_kinds() end)
    end

    test "taking the number another board had is said, with the board it came from", %{conn: conn} do
      a = dgt("FAKE-A", "10001")
      b = dgt("FAKE-B", "10002")
      {:ok, _} = Tables.set_table(a, 1)
      {:ok, view, _html} = live(conn, ~p"/boards")

      number(view, b, 1)
      assert slot(b) == {1, 1, 1}
      assert slot(a) == {nil, nil, nil}
      assert has_element?(view, "#flash-info", "\"DGT FAKE-A\" no longer has table 1")
    end
  end
end
