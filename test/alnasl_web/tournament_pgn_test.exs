defmodule AlnaslWeb.TournamentPgnTest do
  @moduledoc """
  One PGN builder for everything the box writes out, and the whole
  tournament as a download: the same headers in a single game, a round and
  the lot, and the same bytes to Lichess as ever.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.Destination.LichessBroadcast
  alias Alnasl.{Games, Outbox}

  defp play(round, board, sans) do
    names = Alnasl.Tournaments.board(own().id, round, board) || %{}
    game = Games.ensure(round, board, %{white: names[:white], black: names[:black]})

    Enum.reduce(sans, game, fn san, game ->
      {game, _replace?} =
        Games.apply_event(game, {:moves, [%{san: san, flags: [], clock: nil}]}, 1_000)

      Outbox.enqueue(game, nil, false)
    end)
  end

  test "the box's own PGN carries Elo, titles and the players' names as the pairing program has them" do
    game = play(1, 1, ~w(e4 e5))
    pgn = Games.pgn(game)

    assert pgn =~ ~s([White "Player 1"])
    assert pgn =~ ~s([WhiteTitle "GM"])
    assert pgn =~ ~s([WhiteElo "2001"])
    assert pgn =~ ~s([BlackElo "2002"])
    assert File.read!(Games.pgn_path(game)) == pgn
  end

  test "Lichess gets exactly the box's PGN" do
    game = play(1, 1, ~w(e4 e5 Nf3))
    assert LichessBroadcast.pgn(game) == Games.pgn(game)
  end

  test "a round and the whole tournament are those games, in order", %{conn: conn} do
    play(1, 1, ~w(e4 e5))
    play(1, 2, ~w(d4 d5))
    play(2, 1, ~w(c4 e5))

    assert Games.tournament_pgn(own().id) =~ ~s([Round "2"])

    body = conn |> get(~p"/files/tournament") |> response(200)
    assert body =~ ~s([Round "1"]) and body =~ ~s([Round "2"])
    assert body =~ ~s([WhiteElo "2001"])
    assert length(Regex.scan(~r/^\[Event /m, body)) == 3
    assert body == Games.tournament_pgn(own().id)

    assert conn |> get(~p"/files/t/#{own().id}/tournament") |> response(200)
  end

  test "the PGN page offers it", %{conn: conn} do
    play(1, 1, ~w(e4 e5))
    {:ok, view, _html} = live(conn, ~p"/pgn")
    assert has_element?(view, "#export-tournament[href='/files/tournament']")
  end
end
