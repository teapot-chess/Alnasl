defmodule Alnasl.CaptureRecoveryTest do
  @moduledoc """
  A game read back from the box's own capture files
  (`Alnasl.BoardHistory.Capture`): from the last starting position, taken
  only when it ends on the board as it stands, and trusted over a stored
  row begun at the wrong moment (2026-11-23, tournament 311).
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{Chess, Position}
  alias Alnasl.BoardHistory.Capture
  alias Alnasl.CaptureFixtures

  setup do
    root = CaptureFixtures.temp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "the game since the last starting position, all of it", %{root: root} do
    sans = CaptureFixtures.game(86)
    # Yesterday's game first, then the pieces set up again and today's.
    CaptureFixtures.write(root, 5, CaptureFixtures.game(12),
      file: "20261122-180000.jsonl",
      t0: 1_795_000_000_000
    )

    CaptureFixtures.write(root, 5, sans, file: "20261123-140000.jsonl", t0: 1_795_100_000_000)

    assert {:ok, ^sans} =
             Capture.recover(5, root: root, target: CaptureFixtures.board_after(sans))
  end

  test "a game spread over several files is read across them", %{root: root} do
    sans = CaptureFixtures.game(40)
    {first, second} = CaptureFixtures.lines(sans) |> Enum.split(25)
    CaptureFixtures.write_lines(root, 6, first, "20261123-140000.jsonl")
    CaptureFixtures.write_lines(root, 6, second, "20261123-150000.jsonl")

    assert {:ok, ^sans} =
             Capture.recover(6, root: root, target: CaptureFixtures.board_after(sans))
  end

  test "nothing when the replay does not reach the board as it stands", %{root: root} do
    sans = CaptureFixtures.game(30)
    CaptureFixtures.write(root, 7, sans)

    # The board shows one move more than the capture has.
    assert {:error, :does_not_reach} =
             Capture.recover(7,
               root: root,
               target: CaptureFixtures.board_after(CaptureFixtures.game(31))
             )

    # A piece too many, set down by a hand: no legal game ends there.
    final = CaptureFixtures.board_after(sans)
    empty = Enum.find(0..63, &(elem(final, &1) == nil))
    knocked = put_elem(final, empty, {:w, :q})
    assert {:error, :does_not_reach} = Capture.recover(7, root: root, target: knocked)
  end

  test "nothing without captures, or without a starting position in them", %{root: root} do
    assert {:error, :no_capture} = Capture.recover(8, root: root, target: Position.start())

    sans = CaptureFixtures.game(10)

    lines =
      sans
      |> CaptureFixtures.lines()
      |> Enum.reject(&(&1["b"] == Position.to_text(Position.start())))

    CaptureFixtures.write_lines(root, 9, lines, "20261123-140000.jsonl")

    assert {:error, :no_start} =
             Capture.recover(9, root: root, target: CaptureFixtures.board_after(sans))
  end

  describe "the stored plies of a recovered line" do
    test "a row begun at ply 23 with one move: the line wins, that move keeps its time" do
      sans = CaptureFixtures.game(86)
      {:ok, played} = Chess.replay(Chess.start_fen(), sans)
      stale_start = Enum.at(played, 22).fen

      stored = [
        %{"san" => Enum.at(sans, 23), "flags" => [], "at" => 123, "clock" => %{"white_ms" => 1}}
      ]

      plies = Capture.plies(sans, stale_start, stored)
      assert length(plies) == 86
      assert Enum.map(plies, & &1["san"]) == sans
      assert Enum.at(plies, 23) == hd(stored)

      others = List.delete_at(plies, 23)

      assert Enum.all?(
               others,
               &(&1["flags"] == ["imported"] and &1["at"] == nil and &1["clock"] == nil)
             )
    end

    test "stored moves from the standard start are its head and keep their times" do
      sans = CaptureFixtures.game(20)

      stored =
        for san <- Enum.take(sans, 5),
            do: %{"san" => san, "flags" => [], "at" => 9, "clock" => nil}

      plies = Capture.plies(sans, nil, stored)
      assert Enum.take(plies, 5) == stored
      assert Enum.all?(Enum.drop(plies, 5), &(&1["flags"] == ["imported"]))
    end

    test "stored moves that are not in the line keep nothing" do
      sans = CaptureFixtures.game(20)
      stored = [%{"san" => "h4", "flags" => [], "at" => 9, "clock" => nil}]
      assert Enum.all?(Capture.plies(sans, nil, stored), &(&1["flags"] == ["imported"]))
    end
  end
end
