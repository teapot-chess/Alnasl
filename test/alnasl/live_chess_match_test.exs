defmodule Alnasl.LiveChessMatchTest do
  @moduledoc """
  A LiveChess board put on its pairing by who is playing: by FIDE ID, by
  name in any order and spelling of case and accents, the colours
  reversed (and said), a team event's board within its match, the
  arbiter's pick when nothing fits, two games that want one pairing, the
  result as a suggestion, and the names a hall without OpenPairings gets.
  The players are made up.
  """

  use Alnasl.HallCase, async: false

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, LiveChessMatch, Tournaments}

  @moduletag :capture_log

  describe "the same player" do
    test "names: case, accents, punctuation and order do not matter" do
      assert LiveChessMatch.words("Vermeulen, Wanda") == LiveChessMatch.words("WANDA vermeulen")
      assert LiveChessMatch.words("Quaghébeur, Inès") == LiveChessMatch.words("Ines Quaghebeur")
      assert LiveChessMatch.words("Van der Berg-Smit, J.") == ~w(berg der j smit van)

      assert LiveChessMatch.same_player?(%{name: "Duym, Kasper"}, %{name: "Kasper Duym"})
      refute LiveChessMatch.same_player?(%{name: "Duym, Kasper"}, %{name: "Duym, Kaspar"})
      refute LiveChessMatch.same_player?(%{name: ""}, %{name: ""})
    end

    test "a FIDE ID on both sides decides, whatever the names say" do
      assert LiveChessMatch.same_player?(%{name: "W. V.", fide_id: 9_990_001}, %{
               name: "Vermeulen, Wanda",
               fide_id: 9_990_001
             })

      refute LiveChessMatch.same_player?(%{name: "Vermeulen, Wanda", fide_id: 9_990_001}, %{
               name: "Vermeulen, Wanda",
               fide_id: 9_990_002
             })

      # One side without an ID: the names.
      assert LiveChessMatch.same_player?(%{name: "Wanda Vermeulen"}, %{
               name: "Vermeulen, Wanda",
               fide_id: 9_990_001
             })
    end

    test "a pairing fits straight, reversed, or not at all" do
      pairings = [
        %{board: 1, white: %{name: "Brask, Otto"}, black: %{name: "Taelman, Ruben"}},
        %{board: 2, white: %{name: "Ysebaert, Lotte"}, black: %{name: "Duym, Kasper"}}
      ]

      facts = %{white: %{name: "Lotte Ysebaert"}, black: %{name: "Kasper Duym"}}
      assert [{%{board: 2}, :straight}] = LiveChessMatch.judge(facts, pairings)

      facts = %{white: %{name: "Ruben Taelman"}, black: %{name: "Otto Brask"}}
      assert [{%{board: 1}, :reversed}] = LiveChessMatch.judge(facts, pairings)

      assert [] = LiveChessMatch.judge(%{white: %{name: "Otto Brask"}}, pairings)
    end
  end

  # --- boards ------------------------------------------------------------------

  defp livechess_board(n) do
    {:ok, board} =
      Boards.create(%{
        name: "LiveChess##{n}",
        driver: "remote",
        port: "bridge-77:LiveChess##{n}"
      })

    eventually(fn -> Alnasl.BoardServer.whereis(board.id) end)
    board
  end

  defp say(board, facts),
    do: send(Alnasl.BoardServer.whereis(board.id), {:driver, board.id, {:game, facts}})

  defp facts(white, black, extra \\ %{}) do
    Map.merge(
      %{source: "livechess", round: 1, game: 1, result: "*", white: white, black: black},
      extra
    )
  end

  defp match_of(board),
    do: eventually(fn -> get_in(Boards.snapshot(board.id), [:livechess, :match]) end)

  defp on?(board, tid, round, no) do
    row = Boards.get!(board.id)
    {row.tournament_id, row.round, row.board_no} == {tid, round, no}
  end

  describe "an individual tournament" do
    setup do
      pairing_program()
      t = linked(41, name: "Open", boards: 3)
      {:ok, t: t}
    end

    test "the players of a pairing put the board on it", %{t: t} do
      board = livechess_board(1)
      say(board, facts(%{name: "player 3, open"}, %{name: "Open Player 4"}))

      eventually(fn -> on?(board, t.id, 1, 2) end)
      assert %{status: :placed, reversed?: false} = match_of(board)

      # Names and ratings come from the pairing program, as for a DGT board.
      eventually(fn -> Boards.snapshot(board.id)[:white] == "Open Player 3" end)
    end

    test "colours the other way round: placed, and said", %{t: t} do
      board = livechess_board(1)
      say(board, facts(%{name: "Open Player 6"}, %{name: "Open Player 5"}))

      eventually(fn -> on?(board, t.id, 1, 3) end)
      eventually(fn -> match?(%{status: :placed, reversed?: true}, match_of(board)) end)
    end

    test "nobody of the round: on no pairing, the arbiter picks one", %{t: t} do
      board = livechess_board(1)
      say(board, facts(%{name: "Open Player 1"}, %{name: "Somebody Else"}))

      %{status: :none, candidates: [candidate]} =
        eventually(fn ->
          case match_of(board) do
            %{status: :none} = m -> m
            _other -> nil
          end
        end)

      # The one pairing with one of the two players in it.
      assert %{tid: tid, round: 1, board: 1} = candidate
      assert tid == t.id
      refute on?(board, t.id, 1, 1)

      assert :ok = LiveChessMatch.choose(board.id, t.id, 1, 1)
      assert on?(board, t.id, 1, 1)
      assert %{status: :manual} = match_of(board)

      # The pick stands while the players are the same.
      LiveChessMatch.consider(board.id)
      assert on?(board, t.id, 1, 1)
    end

    test "two games with the same players: neither gets the pairing", %{t: t} do
      one = livechess_board(1)
      say(one, facts(%{name: "Open Player 1"}, %{name: "Open Player 2"}))
      eventually(fn -> on?(one, t.id, 1, 1) end)

      two = livechess_board(2)
      say(two, facts(%{name: "Open Player 1"}, %{name: "Open Player 2"}, %{game: 2}))

      eventually(fn -> match?(%{status: :claimed}, match_of(two)) end)
      eventually(fn -> match?(%{status: :claimed}, match_of(one)) end)
      refute on?(one, t.id, 1, 1)
      refute on?(two, t.id, 1, 1)
    end

    test "a decided result in the file is suggested, not entered", %{t: t} do
      board = livechess_board(1)
      say(board, facts(%{name: "Open Player 1"}, %{name: "Open Player 2"}))
      eventually(fn -> on?(board, t.id, 1, 1) end)

      say(board, facts(%{name: "Open Player 1"}, %{name: "Open Player 2"}, %{result: "0-1"}))
      eventually(fn -> Boards.snapshot(board.id)[:suggestion] == "0-1" end)
      assert Boards.snapshot(board.id).result == nil
    end

    test "the next round: its players, its pairing", %{t: t} do
      board = livechess_board(1)
      say(board, facts(%{name: "Open Player 1"}, %{name: "Open Player 2"}))
      eventually(fn -> on?(board, t.id, 1, 1) end)

      # Round 2 pairs player 1 against player 2 again on board 1, so the
      # other players are made to meet: board 3's players now.
      FakeOpenPairings.pair(41, 2, 3)
      poll()
      Boards.start_round(t.id, 2)

      say(board, facts(%{name: "Open Player 5"}, %{name: "Open Player 6"}, %{round: 2}))
      eventually(fn -> on?(board, t.id, 2, 3) end)
    end
  end

  describe "a team event" do
    setup do
      pairing_program()
      FakeOpenPairings.add_team_tournament(42, name: "Interclub")
      {:ok, _link, _found} = Alnasl.OpenPairings.add_code(FakeOpenPairings.code(42))
      {:ok, event: by_remote(42)}
    end

    test "the board within its match, colours as the match gives them", %{event: event} do
      # Match 2, board 2: Team 4 has White there.
      board = livechess_board(6)
      say(board, facts(%{name: "Interclub T4 P2"}, %{name: "Interclub T3 P2"}))

      eventually(fn -> on?(board, event.id, 1, 6) end)
      assert %{status: :placed, reversed?: false} = match_of(board)
      assert %{match: %{number: 2, board: 2}} = Tournaments.board(event.id, 1, 6)
    end
  end

  describe "without OpenPairings" do
    test "a board linked in the box's own tournament takes LiveChess's names" do
      board = livechess_board(1)
      say(board, facts(%{name: "Vermeulen, Wanda"}, %{name: "Brask, Otto"}))
      assert %{status: :standalone} = match_of(board)

      # Board 9: the box's own tournament has no names there yet.
      Boards.link(Boards.get!(board.id), 1, 9)

      eventually(fn ->
        match?(%{white: "Vermeulen, Wanda", black: "Brask, Otto"}, Boards.snapshot(board.id))
      end)
    end
  end
end
