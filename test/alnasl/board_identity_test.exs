defmodule Alnasl.BoardIdentityTest do
  @moduledoc """
  A board is the board, not the cable: the same DGT board plugged into
  another port, another hub, another adapter or another bridge of the hall
  brings its own row back - name, table, game and all - and leaves no
  second row behind. Whether the old row had a number or not, whether the
  old port has noticed yet that the cable is out or not.
  """

  use Alnasl.HallCase

  # A bridge stopped at the end of a test may grumble; not news.
  @moduletag :capture_log

  alias Alnasl.{Bridges, BoardServer, Finder, Halls, Tables}
  alias Alnasl.Driver.Remote
  alias Alnasl.Halls.Hall
  alias Arkab.Dgt.Emulator
  alias Arkab.Transport.Fake

  setup do
    Finder.reset()
    on_exit(fn -> Finder.reset() end)
    :ok
  end

  defp device(port, serial, position \\ Position.start()) do
    start_supervised!(
      {Fake, port: port, device: {Emulator, Emulator.new(serial: serial, board: position)}},
      id: port
    )
  end

  # A DGT board in software that reports `serial` on `port`, and its row.
  defp dgt(port, serial, attrs \\ %{}) do
    device(port, serial)

    {:ok, board} =
      Boards.create(Map.merge(%{name: "DGT " <> port, driver: "dgt_serial", port: port}, attrs))

    eventually(fn -> Boards.get!(board.id).serial == serial end)
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    Boards.get!(board.id)
  end

  # The board on a new port, added by hand as the arbiter would: a new row.
  defp replug(port, serial, position \\ Position.start()) do
    device(port, serial, position)
    {:ok, added} = Boards.create(%{name: "Board new", driver: "dgt_serial", port: port})
    added
  end

  # The one row left, and it is the board's.
  defp only_row(serial) do
    eventually(fn ->
      case Boards.list() do
        [%{serial: ^serial} = row] -> row
        _more -> nil
      end
    end)
  end

  describe "on the box's own ports" do
    test "an un-numbered board on another port is its old row again, not a second one" do
      old = dgt("FAKE-OLD", "06310", %{name: "Spare"})
      assert Tables.new?(old)
      Boards.disconnect(old)
      stop_supervised!("FAKE-OLD")

      added = replug("FAKE-NEW", "06310")

      eventually(fn -> Boards.get(added.id) == nil end)
      assert [%{id: id, port: "FAKE-NEW", name: "Spare", enabled: true}] = Boards.list()
      assert id == old.id
      eventually(fn -> Boards.snapshot(old.id).connected? end)
    end

    test "replugged before the old port noticed: the rows become one when it does" do
      old = dgt("FAKE-OLD", "06310", %{name: "Top board"})
      {:ok, _} = Tables.set_table(old, 3)

      # The cable goes into the other hub; the old port has not heard yet.
      added = replug("FAKE-NEW", "06310")
      eventually(fn -> Boards.get!(added.id).serial == "06310" end)
      eventually(fn -> Boards.snapshot(added.id).connected? end)
      assert Tables.recognise(added.id) == :duplicate
      assert length(Boards.list()) == 2

      # And now it has.
      stop_supervised!("FAKE-OLD")

      row = only_row("06310")
      assert %{port: "FAKE-NEW", name: "Top board", table_no: 3, board_no: 3} = row
      assert row.id == old.id
      eventually(fn -> Boards.snapshot(old.id).connected? end, 15_000)
      assert "board.recognised" in log_kinds()
    end

    test "mid-game, replugged in a hurry: the game goes on, on the same row" do
      old = dgt("FAKE-OLD", "06310", %{name: "Top board"})
      {:ok, _} = Tables.set_table(old, 2)
      play_on("FAKE-OLD", old.id, ~w(e4 e5))

      replug("FAKE-NEW", "06310", List.last(boards_after(~w(e4 e5))))
      stop_supervised!("FAKE-OLD")

      row = only_row("06310")
      assert %{id: id, port: "FAKE-NEW", table_no: 2, board_no: 2} = row
      assert id == old.id
      eventually(fn -> Boards.snapshot(old.id).connected? end, 15_000)

      play_on("FAKE-NEW", old.id, ~w(Nf3), ~w(e4 e5))
      assert Games.sans(Games.get(1, 2)) == ~w(e4 e5 Nf3)
    end

    test "a board that was on a loop, now alone on a port, is its loop row again" do
      {:ok, looped} =
        Boards.create(%{
          name: "Board 5",
          driver: "dgt_bus",
          port: "FAKE-LOOP",
          address: 5,
          serial: "06310",
          options: %{}
        })

      {:ok, _} = Tables.set_table(looped, 4)
      Boards.disconnect(Boards.get!(looped.id))

      replug("FAKE-NEW", "06310")

      row = only_row("06310")
      assert %{driver: "dgt_serial", port: "FAKE-NEW", table_no: 4, name: "Board 5"} = row
      assert row.id == looped.id
    end

    test "a row numbered before its board said who it is merges into the known row" do
      known = dgt("FAKE-OLD", "06310", %{name: "Known"})
      {:ok, _} = Tables.set_table(known, 1)
      Boards.disconnect(Boards.get!(known.id))
      stop_supervised!("FAKE-OLD")

      # A row on a port with nothing to read yet, given a number all the same.
      {:ok, temp} = Boards.create(%{name: "Temp", driver: "dgt_serial", port: "FAKE-NEW"})
      {:ok, _} = Tables.set_table(temp, 9)

      # The board is plugged in and says who it is: one row, the known one,
      # with its own number - the temporary row had no game begun.
      device("FAKE-NEW", "06310")
      row = eventually(fn -> Boards.get(temp.id) == nil and only_row("06310") end, 15_000)
      assert %{id: id, port: "FAKE-NEW", table_no: 1, name: "Known"} = row
      assert id == known.id
      assert length(Boards.list()) == 1
    end

    test "a numbered row on the new port keeps its number; the un-numbered leftover goes" do
      leftover = dgt("FAKE-OLD", "06310", %{name: "Leftover"})
      Boards.disconnect(leftover)
      stop_supervised!("FAKE-OLD")

      {:ok, temp} = Boards.create(%{name: "Table 6", driver: "dgt_serial", port: "FAKE-NEW"})
      {:ok, _} = Tables.set_table(temp, 6)
      device("FAKE-NEW", "06310")

      row = eventually(fn -> Boards.get(leftover.id) == nil and only_row("06310") end, 15_000)
      assert %{id: id, table_no: 6, name: "Table 6", port: "FAKE-NEW"} = row
      assert id == temp.id
    end

    test "kept as it was: the same board read twice at once is reported, not merged" do
      one = dgt("FAKE-1", "33333")
      {:ok, _} = Tables.set_table(one, 1)
      two = dgt("FAKE-2", "33333")

      assert Tables.recognise(two.id) == :duplicate
      assert length(Boards.list()) == 2
      assert Enum.any?(Tables.checks(1), &match?(%{what: {:same_serial, "33333", _}}, &1))
    end
  end

  describe "through bridges" do
    defp hall(name) do
      hall = Repo.insert!(%Hall{name: name, own: false})
      Halls.local_tournament(hall)
      hall
    end

    defp bridge(hall, uid) do
      {:ok, join} = Bridges.create_join(DateTime.utc_now(:second), hall.id)

      {:ok, %{bridge: bridge}} =
        Bridges.redeem(join.code, %{
          "v" => 1,
          "bridge" => uid,
          "name" => uid,
          "software" => "arkab"
        })

      bridge
    end

    # The bridge's link, up: this test process stands in for its socket.
    defp link_up(bridge) do
      {:ok, _} = Registry.register(Alnasl.BridgeRegistry, bridge.id, %{boards: []})
      :ok
    end

    # What the bridge says of a board, as its socket hands it on.
    defp say(row, events) do
      pid = eventually(fn -> Remote.whereis(row.port) end)
      t = System.monotonic_time(:millisecond)

      events =
        events |> Enum.with_index() |> Enum.map(fn {e, i} -> %{t: t + i, at: nil, event: e} end)

      :ok = pid |> Remote.deliver(events) |> BoardServer.sync()
    end

    defp seen(row, serial),
      do: say(row, [:connected, {:info, %{serial: serial}}, {:position, Position.start()}])

    test "carried to another bridge of the hall while the first is down: its own row" do
      annex = hall("Annex")
      one = bridge(annex, "pi-one")
      two = bridge(annex, "pi-two")
      link_up(two)

      {:ok, first} = Bridges.board_row(one, "/dev/ttyUSB0")
      {:ok, first} = Boards.update(first, %{serial: "06310"})
      {:ok, first} = Tables.set_table(first, 5)

      {:ok, second} = Bridges.board_row(two, "/dev/ttyUSB3")
      seen(second, "06310")

      row = only_row("06310")
      assert row.id == first.id
      assert %{port: port, table_no: 5, hall_id: hall_id} = row
      assert port == Bridges.port(two, "/dev/ttyUSB3") and hall_id == annex.id
    end

    test "another USB port of the same bridge, the old one not yet timed out" do
      annex = hall("Annex")
      pi = bridge(annex, "pi")
      link_up(pi)

      {:ok, first} = Bridges.board_row(pi, "/dev/ttyUSB0")
      seen(first, "06310")
      {:ok, _} = Tables.set_table(Boards.get!(first.id), 2)

      {:ok, second} = Bridges.board_row(pi, "/dev/ttyUSB1")
      seen(second, "06310")
      assert Tables.recognise(second.id) == :duplicate

      # The bridge's old port gives up on the board.
      say(Boards.get!(first.id), [:disconnected])

      row = only_row("06310")
      assert row.id == first.id
      assert %{table_no: 2, port: port} = row
      assert port == Bridges.port(pi, "/dev/ttyUSB1")
    end

    test "never across halls: the other hall's row is left alone" do
      annex = hall("Annex")
      cellar = hall("Cellar")
      a = bridge(annex, "pi-annex")
      c = bridge(cellar, "pi-cellar")
      link_up(c)

      {:ok, first} = Bridges.board_row(a, "/dev/ttyUSB0")
      {:ok, first} = Boards.update(first, %{serial: "06310"})
      {:ok, _} = Tables.set_table(first, 5)

      {:ok, second} = Bridges.board_row(c, "/dev/ttyUSB0")
      seen(second, "06310")
      assert Tables.recognise(second.id) == :new

      assert %{table_no: 5, hall_id: hall_id} = Boards.get!(first.id)
      assert hall_id == annex.id
      assert Boards.get!(second.id).hall_id == cellar.id
    end
  end
end
