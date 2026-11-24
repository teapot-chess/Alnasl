defmodule Alnasl.BeginFromBoardTest do
  @moduledoc """
  The hall test of 2026-11-21: the clock starts the game from whatever is
  on the board, and a board without a clock can be told to play without
  one, starting at the round's start time.
  """

  use Alnasl.HallCase

  alias Alnasl.{Chess, Tournaments}

  @ruy ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7)

  test "the clock started over a position that is not the start: the game starts from it" do
    board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
    eventually(fn -> Boards.snapshot(board.id).raw end)

    position = List.last(boards_after(@ruy))
    set_pieces("FAKE1", position)
    eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(position) end)
    assert Boards.snapshot(board.id).plies == []

    # White to move, White's clock started.
    set_clock("FAKE1", :white)
    eventually(fn -> "game.from_board" in log_kinds() end, 8_000)

    snapshot = Boards.snapshot(board.id)
    assert snapshot.start_fen == Position.fen(position, :w)
    assert snapshot.plies == []
    game = Games.get(1, 1)
    assert game.start_fen == Position.fen(position, :w)

    # And it is followed from there.
    {:ok, played} = Chess.replay(snapshot.start_fen, ~w(Re1))
    set_pieces("FAKE1", Position.from_fen(List.last(played).fen))
    eventually(fn -> sans(board.id) == ~w(Re1) end)
  end

  test "the starting position on the board is a game like any other: nothing is restarted" do
    board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
    eventually(fn -> Boards.snapshot(board.id).raw end)
    set_clock("FAKE1", :white)
    eventually(fn -> match?(%{running: :white}, Boards.snapshot(board.id).clock) end)
    played = play_on("FAKE1", board.id, ~w(e4))
    set_clock("FAKE1", :black)
    play_on("FAKE1", board.id, ~w(e5), played)

    refute "game.from_board" in log_kinds()
    assert Games.get(1, 1).start_fen == nil
  end

  test "without a clock the box waits; told to play without one, the game begins" do
    board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
    eventually(fn -> Boards.snapshot(board.id).raw end)
    snapshot = Boards.snapshot(board.id)
    assert snapshot.status == :waiting_start and snapshot.clock == nil
    assert snapshot.started_without_clock == nil

    # The box's own tournament has no start time from OpenPairings: at once.
    Tournaments.set_no_clock(Tournaments.default_id(), true)
    eventually(fn -> Boards.snapshot(board.id).started_without_clock != nil end)
    assert Boards.snapshot(board.id).status == :live
    assert "game.started_without_clock" in log_kinds()

    play_on("FAKE1", board.id, ~w(e4 e5))
    assert sans(board.id) == ~w(e4 e5)
  end

  test "without a clock the start time is read on the hall's wall clock, not the box's" do
    tournament = Tournaments.default()
    # Ahead of UTC by fourteen hours: an hour ago there is still the future
    # on a box that keeps UTC.
    zone = "Pacific/Kiritimati"
    started = Alnasl.Zone.local_now(zone) |> NaiveDateTime.add(-3600)

    Tournaments.update(tournament, %{
      document:
        Jason.encode!(%{
          "rounds" => [
            %{
              "number" => 1,
              "date" => Date.to_iso8601(NaiveDateTime.to_date(started)),
              "time" => Calendar.strftime(started, "%H:%M"),
              "boards" => []
            }
          ]
        })
    })

    Alnasl.Halls.own() |> Ecto.Changeset.change(time_zone: zone) |> Repo.update!()

    board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
    eventually(fn -> Boards.snapshot(board.id).raw end)
    Tournaments.set_no_clock(tournament.id, true)
    eventually(fn -> Boards.snapshot(board.id).started_without_clock != nil end)
  end

  test "the round's start time comes from the pairing program's date and time" do
    tournament = Tournaments.default()

    Tournaments.update(tournament, %{
      document:
        Jason.encode!(%{
          "rounds" => [
            %{"number" => 1, "date" => "2026-11-21", "time" => "14:30", "boards" => []},
            %{"number" => 2, "date" => "2026-11-22", "boards" => []}
          ]
        })
    })

    assert Tournaments.round_start(tournament.id, 1) == ~N[2026-11-21 14:30:00]
    # A date without a time is no start time.
    assert Tournaments.round_start(tournament.id, 2) == nil
    assert Tournaments.round_start(tournament.id, 3) == nil
  end
end
