defmodule Alnasl.BoardLogTest do
  @moduledoc """
  The board debug log: a ring per board, and lines that say what the board
  read, what was made of it, and - above all - why a result is what it is.
  """

  use Alnasl.HallCase

  alias Alnasl.BoardLog
  alias AlnaslWeb.BoardLogWords

  setup do
    BoardLog.clear_all()
    on_exit(&BoardLog.clear_all/0)
    :ok
  end

  defp lines(board_id, kind), do: board_id |> BoardLog.list() |> Enum.filter(&(&1.kind == kind))

  defp texts(board_id), do: board_id |> BoardLog.list() |> Enum.map(&BoardLogWords.text/1)

  describe "the ring" do
    test "newest first, bounded, per board, and gone with the board" do
      for n <- 1..(BoardLog.keep() + 60), do: BoardLog.add(9001, :other, "n#{n}")
      BoardLog.add(9002, :other, "other board")

      lines = BoardLog.list(9001)
      assert length(lines) <= BoardLog.keep() + 50
      assert length(lines) >= BoardLog.keep()
      assert hd(lines).kind == "n#{BoardLog.keep() + 60}"
      assert [%{kind: "other board"}] = BoardLog.list(9002)

      BoardLog.clear(9001)
      assert BoardLog.list(9001) == []
      assert [_] = BoardLog.list(9002)
    end

    test "the arbiter's lines about a board are copied in, in that log's words" do
      Alnasl.Log.add(:warn, "board.disconnected", %{}, %{board_id: 9003})
      assert [%{kind: "log", cat: :connection, level: :warn} = line] = BoardLog.list(9003)
      assert BoardLogWords.text(line) == AlnaslWeb.Words.log(line.data.event)
    end
  end

  describe "a real board" do
    test "a move: the squares read, the move made of them, and on what grounds" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)
      play_on("FAKE1", board.id, ~w(e4))

      eventually(fn -> lines(board.id, "move") != [] end)
      [move] = lines(board.id, "move")
      assert %{san: "e4", from: "e2", to: "e4", piece: {:w, :p}, flags: []} = move.data
      assert move.tech =~ "from FEN rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w"
      assert BoardLogWords.text(move) =~ "e4 recognised: white pawn from e2 to e4"

      assert Enum.any?(lines(board.id, "position"), fn line ->
               Enum.any?(line.data.changes || [], &match?({_sq, {:w, :p}, nil}, &1))
             end)

      assert Enum.any?(texts(board.id), &(&1 =~ "lifted from e2" or &1 =~ "set down on e4"))
      assert lines(board.id, "driver.started") != []
      assert lines(board.id, "game.linked") != []
      assert lines(board.id, "queued") != []
    end

    test "a result from the gesture says which squares the kings stand on, and that it waits" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)
      play_on("FAKE1", board.id, ~w(e4 e5))

      # White king on d5, black king on e4: both light squares, 1-0.
      now = List.last(boards_after(~w(e4 e5)))
      gesture = now |> put_elem(60, nil) |> put_elem(4, nil) |> put_elem(27, {:w, :k})
      set_pieces("FAKE1", put_elem(gesture, 36, {:b, :k}))

      eventually(fn -> lines(board.id, "result.why") != [] end)
      [why] = lines(board.id, "result.why")
      assert %{result: "1-0", why: :gesture, white_king: "d5", black_king: "e4"} = why.data
      text = BoardLogWords.text(why)
      assert text =~ "d5" and text =~ "e4" and text =~ "White won"

      [waits] = eventually(fn -> lines(board.id, "result.waits") |> then(&(&1 != [] && &1)) end)
      assert waits.data.fact == false
      assert BoardLogWords.text(waits) =~ "never taken as a result by itself"
    end

    test "a result set by hand says by whom, and whether the board agreed" do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)
      play_on("FAKE1", board.id, ~w(e4))

      assert :ok = Boards.set_result(board.id, "0-1", "openpairings")
      [line] = lines(board.id, "result.by_hand")
      assert %{result: "0-1", by: "openpairings"} = line.data
      assert BoardLogWords.text(line) =~ "OpenPairings"

      # The arbiter's own line says the same.
      assert Enum.any?(texts(board.id), &(&1 =~ "set by the arbiter in OpenPairings"))
    end
  end

  describe "the words" do
    defp entry(kind, data), do: %{kind: kind, data: data, cat: :result, tech: nil, level: :info}

    test "mate, stalemate and the setting that decides whether it is sent by itself" do
      assert BoardLogWords.text(
               entry("result.why", %{result: "1-0", why: :checkmate, turn: :b, last: "Rd8#"})
             ) =~ "Black is checkmated after Rd8#"

      assert BoardLogWords.text(
               entry("result.why", %{result: "1/2-1/2", why: :stalemate, turn: :w})
             ) =~ "stalemate"

      assert BoardLogWords.text(entry("result.auto", %{result: "1-0"})) =~ "is on"

      assert BoardLogWords.text(entry("result.waits", %{result: "1-0", fact: true, auto: false})) =~
               "is off"
    end

    test "what a destination said" do
      assert BoardLogWords.text(
               entry("sent", %{destination: "openresults", outcome: :sent, detail: nil, seq: 4})
             ) == "The results site took update 4."

      assert BoardLogWords.text(
               entry("sent", %{
                 destination: "lichess",
                 outcome: :rejected,
                 detail: "invalid_moves",
                 seq: 5
               })
             ) =~ "Lichess refused update 5"
    end
  end
end
