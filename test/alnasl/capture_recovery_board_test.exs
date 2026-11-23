defmodule Alnasl.CaptureRecoveryBoardTest do
  @moduledoc """
  A board's process reading its own captures back (`from_capture/2`):
  linked mid-game to a game with no moves, and stuck out of sync on a game
  row begun at the wrong moment - the two things 2026-11-23, tournament 311
  left behind. The board's own readings are written by the box as always;
  the game before them is a capture file the test lays down.
  """

  use Alnasl.HallCase

  alias Alnasl.{BoardServer, CaptureFixtures, Games, Paths, Tournaments}

  @moduletag :capture_log

  # A board that has been read and is now quiet: its transport unplugged,
  # its own capture so far cleared, so that the test's file is the history.
  defp quiet_board do
    board = fake_dgt("FAKE1")
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    Arkab.Transport.Fake.unplug("FAKE1")
    eventually(fn -> not Boards.snapshot(board.id).connected? end)
    Recorder.flush()
    File.rm_rf!(Path.join(Paths.captures(), "board-#{board.id}"))
    board
  end

  defp capture(board, sans),
    do: CaptureFixtures.write(Paths.captures(), board.id, sans, file: "20000101-000000.jsonl")

  defp driver(board, event) do
    pid = BoardServer.whereis(board.id)
    send(pid, {:driver, board.id, event})
    :ok = BoardServer.sync(pid)
  end

  defp game(no), do: Games.current(Tournaments.default_id(), 1, no)
  defp count(kind), do: length(Alnasl.Log.list(kind: kind))

  # The whole line reached the results server, replacing what it held.
  defp sent(no, sans) do
    eventually(fn ->
      Outbox.drain()
      match?(%{moves: ^sans}, FakeIngest.game(1, no))
    end)
  end

  # What asked for the recording to be read.
  defp why,
    do: Alnasl.Log.data(hd(Alnasl.Log.list(kind: "board.history_recovered")))["why"]

  test "linked mid-game: the game comes back from the captures, whole, and is sent so" do
    board = quiet_board()
    sans = CaptureFixtures.game(30)
    capture(board, sans)
    driver(board, {:position, CaptureFixtures.board_after(sans)})

    Boards.link(Boards.get!(board.id), 1, 2)

    eventually(fn -> Games.sans(game(2)) == sans end)
    assert game(2).start_fen == nil
    assert Enum.all?(Games.plies(game(2)), &(&1.flags == [:imported] and &1.at == nil))
    eventually(fn -> count("board.history_recovered") == 1 end)
    assert why() == "linked"
    assert count("game.from_board") == 0
    assert Boards.snapshot(board.id).status in [:live, :no_signal]
    sent(2, sans)
  end

  test "a row begun from ply 23 with one move, the board at ply 86: the captures win" do
    board = quiet_board()
    sans = CaptureFixtures.game(86)
    capture(board, sans)
    {:ok, played} = Alnasl.Chess.replay(Alnasl.Chess.start_fen(), sans)

    # The stale row: one move, from the position after ply 23.
    stale = Games.ensure(Tournaments.default_id(), 1, 3, %{})
    clock = %{"white_ms" => 4_000_000, "black_ms" => 4_100_000}

    stale
    |> Ecto.Changeset.change(%{
      start_fen: Enum.at(played, 22).fen,
      plies:
        Jason.encode!([%{"san" => Enum.at(sans, 23), "flags" => [], "at" => 1, "clock" => clock}])
    })
    |> Repo.update!()

    driver(board, {:position, CaptureFixtures.board_after(sans)})
    Boards.link(Boards.get!(board.id), 1, 3)

    eventually(fn -> length(Games.sans(game(3))) == 86 end, 10_000)
    assert Games.sans(game(3)) == sans
    assert game(3).start_fen == nil
    # The one move the row had is in the line, where it was: its time stays.
    assert Enum.at(Games.plies(game(3)), 23).clock == %{white_ms: 4_000_000, black_ms: 4_100_000}
    eventually(fn -> count("board.history_recovered") == 1 end)
    assert why() == "out_of_sync"
    sent(3, sans)
  end

  test "a replay that does not reach the board as it stands changes nothing" do
    board = quiet_board()
    sans = CaptureFixtures.game(30)
    capture(board, sans)
    # A piece too many, set down by a hand: no game the recording has (nor
    # any legal one) ends where the board now stands. (A board one move on
    # would do: the box recorded that reading itself.)
    final = CaptureFixtures.board_after(sans)
    empty = Enum.find(0..63, &(elem(final, &1) == nil))
    driver(board, {:position, put_elem(final, empty, {:w, :q})})

    Boards.link(Boards.get!(board.id), 1, 2)

    eventually(fn -> count("board.history_recovery_failed") == 1 end)
    assert Games.sans(game(2)) == []
    assert count("board.history_recovered") == 0

    [event] = Alnasl.Log.list(kind: "board.history_recovery_failed")
    assert Alnasl.Log.data(event)["reason"] == "does_not_reach"
  end
end
