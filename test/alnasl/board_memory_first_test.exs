defmodule Alnasl.BoardMemoryFirstTest do
  @moduledoc """
  A board that comes back is asked for its memory before anybody guesses at
  the moves it missed: the gap is held back, the memory plays the moves in,
  and nothing is marked guessed. A guess that was made anyway (the memory
  came late, or the wait was switched off) loses its mark when the memory
  agrees with it. The emulated board is on a serial port; where a test needs
  the memory not to come, the driver is left unplugged and its events are
  handed to the board's process by the test.
  """

  use Alnasl.HallCase

  alias Alnasl.{BoardHistory, BoardMemory, BoardServer, Games}

  @line ~w(e4 e5 Nf3 Nc6)

  defp hold(ms) do
    old = Application.get_env(:alnasl, :history_hold_ms)
    Application.put_env(:alnasl, :history_hold_ms, ms)
    on_exit(fn -> Application.put_env(:alnasl, :history_hold_ms, old) end)
  end

  defp board_on(port \\ "FAKE1") do
    board = fake_dgt(port, %{round: 1, board_no: 1})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    board
  end

  defp driver(board, event) do
    pid = BoardServer.whereis(board.id)
    send(pid, {:driver, board.id, event})
    :ok = BoardServer.sync(pid)
  end

  defp flags(board), do: Enum.map(Boards.snapshot(board.id).plies, & &1.flags)
  defp count(kind), do: Enum.count(log_kinds(), &(&1 == kind))

  # The driver lost, with the game two moves in and the board now two moves on.
  defp away_and_back(board) do
    play_on("FAKE1", board.id, ~w(e4 e5))
    Arkab.Transport.Fake.unplug("FAKE1")
    eventually(fn -> Boards.snapshot(board.id).status == :no_signal end)
    board
  end

  describe "the memory comes (the emulated board writes down every move)" do
    test "the missed moves are played in from it: never guessed, no question asked" do
      hold(60_000)
      board = away_and_back(board_on())

      # Two moves are made while nobody listens - one at a time, as a person does.
      for position <- Enum.drop(boards_after(@line), 2), do: set_pieces("FAKE1", position)
      Arkab.Transport.Fake.replug("FAKE1")

      eventually(fn -> sans(board.id) == @line end, 15_000)

      plies = Boards.snapshot(board.id).plies
      refute Enum.any?(plies, &(:guessed in &1.flags))
      assert Enum.all?(Enum.drop(plies, 2), &(:memory in &1.flags))
      kinds = log_kinds()
      refute "move.guessed" in kinds
      assert "board.history_merged" in kinds
      assert "board.history_waiting" in kinds
    end
  end

  describe "the memory does not come" do
    test "the gap is held back, and guessed once the wait is over" do
      hold(2_500)
      board = board_on()
      play_on("FAKE1", board.id, ~w(e4 e5))
      Arkab.Transport.Fake.unplug("FAKE1")
      eventually(fn -> Boards.snapshot(board.id).status == :no_signal end)

      driver(board, :disconnected)
      driver(board, :connected)
      driver(board, {:position, List.last(boards_after(@line))})

      assert sans(board.id) == ~w(e4 e5)
      # Held: the log says what it waits for, and the game has not moved.
      eventually(fn -> count("board.history_waiting") == 1 end)
      assert sans(board.id) == ~w(e4 e5)
      eventually(fn -> sans(board.id) == @line end, 10_000)
      assert count("board.history_late") == 1
      assert "move.guessed" in log_kinds() or "move.recovered" in log_kinds()
    end

    test "a board with no wait (hold off) guesses straight away, as before" do
      hold(0)
      board = away_and_back(board_on())
      driver(board, {:position, List.last(boards_after(@line))})
      eventually(fn -> sans(board.id) == @line end, 10_000)
      assert count("board.history_waiting") == 0
    end
  end

  describe "a guess that the memory then confirms" do
    setup do
      hold(0)
      board = away_and_back(board_on())
      driver(board, :disconnected)
      driver(board, {:position, List.last(boards_after(@line))})
      eventually(fn -> sans(board.id) == @line end, 10_000)
      assert Enum.any?(List.flatten(flags(board)), &(&1 == :guessed))
      %{board: board}
    end

    test "loses its mark, the log says how many, and the game is saved that way", %{board: board} do
      driver(board, {:history, BoardMemory.game(@line)})

      refute Enum.any?(List.flatten(flags(board)), &(&1 == :guessed))
      assert Enum.all?(Enum.drop(Boards.snapshot(board.id).plies, 2), &(:memory in &1.flags))
      assert count("board.history_confirmed") == 1
      assert count("board.history_matches") == 0

      stored = Games.sans(Games.get(1, 1))
      assert stored == @line
      refute Enum.any?(Games.plies(Games.get(1, 1)), &(:guessed in &1.flags))

      # Read again: nothing left to confirm, and the log says it matches.
      driver(board, {:history, BoardMemory.game(@line)})
      assert count("board.history_confirmed") == 1
      assert count("board.history_matches") == 1
    end

    test "a memory that stops short only confirms what it covers", %{board: board} do
      driver(board, {:history, BoardMemory.game(~w(e4 e5 Nf3))})

      plies = Boards.snapshot(board.id).plies
      refute :guessed in Enum.at(plies, 2).flags
      assert :guessed in Enum.at(plies, 3).flags
      assert count("board.history_confirmed") == 1
    end

    test "a memory that cannot be held up against the game says why", %{board: board} do
      driver(board, {:history, []})
      assert count("board.history_unmatched") + count("board.history_matches") == 1
      assert :guessed in Enum.at(Boards.snapshot(board.id).plies, 3).flags
    end
  end

  describe "BoardHistory.merge_detail/2" do
    defp known(sans), do: Enum.map(sans, &%{san: &1, flags: [], clock: nil})

    test "says how many plies the memory agrees with" do
      memory = BoardMemory.game(@line)

      assert {:nothing, 4} = BoardHistory.merge_detail(memory, plies: known(@line))

      assert {:nothing, 2} =
               BoardHistory.merge_detail(BoardMemory.game(~w(e4 e5)), plies: known(@line))

      assert {{:extend, [_, _]}, 2} = BoardHistory.merge_detail(memory, plies: known(~w(e4 e5)))

      assert {{:draft, :conflict, _}, 0} =
               BoardHistory.merge_detail(memory, plies: known(~w(d4 d5)))

      assert {{:unmatched, :not_a_history}, 0} = BoardHistory.merge_detail(:nope, [])
    end

    test "merge/2 answers as it always did" do
      assert :nothing = BoardHistory.merge(BoardMemory.game(@line), plies: known(@line))
    end
  end
end
