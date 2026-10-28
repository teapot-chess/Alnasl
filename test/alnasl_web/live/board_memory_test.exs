defmodule AlnaslWeb.BoardMemoryTest do
  @moduledoc """
  A board that comes back with its own memory (`{:history, events}` from
  its driver): moves that carry the game on are added; another version of
  the game waits on the game page, where the arbiter takes it or leaves it;
  the round page says a board has one waiting. The driver of these tests is
  the emulated board on a serial port; the memory is handed to the board's
  process as a driver would.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.{BoardMemory, BoardServer, MemoryDrafts}

  @opening ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7)

  defp board_on(number) do
    board = fake_dgt("FAKE1", %{round: 1, board_no: number})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    board
  end

  # What a driver does: the memory, as an event of the board's driver.
  defp remember(board, events) do
    send(BoardServer.whereis(board.id), {:driver, board.id, {:history, events}})
    :ok = BoardServer.sync(BoardServer.whereis(board.id))
  end

  defp count(kind), do: Enum.count(log_kinds(), &(&1 == kind))

  test "moves played while nobody read the board are added, marked, once" do
    board = board_on(1)
    play_on("FAKE1", board.id, ~w(e4 e5))

    # The board went away, the game went on, and it is back where it stands now.
    set_pieces("FAKE1", List.last(boards_after(@opening)))
    remember(board, BoardMemory.game(@opening))

    eventually(fn -> sans(board.id) == @opening end)
    assert Games.sans(Games.get(1, 1)) == @opening
    plies = Games.plies(Games.get(1, 1))
    assert Enum.all?(Enum.drop(plies, 2), &(:memory in &1.flags))
    refute Enum.any?(Enum.take(plies, 2), &(:memory in &1.flags))
    eventually(fn -> Boards.snapshot(board.id).status != :out_of_sync end)
    assert count("board.history_merged") == 1

    # The same memory again - the board came back twice: nothing more.
    remember(board, BoardMemory.game(@opening))
    assert Games.sans(Games.get(1, 1)) == @opening
    assert count("board.history_merged") == 1
  end

  test "the game page says which moves came from the board's memory" do
    board = board_on(1)
    play_on("FAKE1", board.id, ~w(e4 e5))
    set_pieces("FAKE1", List.last(boards_after(@opening)))
    remember(board, BoardMemory.game(@opening))
    eventually(fn -> sans(board.id) == @opening end)

    {:ok, view, _html} = live(build_conn(), ~p"/round/1/board/1")
    eventually_html(view, fn _html -> has_element?(view, "#memory-notice") end)
    refute has_element?(view, "#memory-draft")
  end

  describe "another version of the game" do
    setup do
      board = board_on(1)
      play_on("FAKE1", board.id, ~w(e4 e5 Nf3 Nc6))
      remember(board, BoardMemory.game(~w(e4 e5 Nf3 Nf6 Nxe5 d6)))
      %{board: board}
    end

    test "is not played into the game; it waits for the arbiter on the game and round pages",
         %{board: board} do
      assert Games.sans(Games.get(1, 1)) == ~w(e4 e5 Nf3 Nc6)
      assert %{reason: "conflict", from_ply: 3} = MemoryDrafts.pending(Games.get(1, 1).id)
      assert count("board.history_draft") == 1

      # Read again: the same draft, not a second one.
      remember(board, BoardMemory.game(~w(e4 e5 Nf3 Nf6 Nxe5 d6)))
      assert count("board.history_draft") == 1

      {:ok, game, _html} = live(build_conn(), ~p"/round/1/board/1")
      eventually_html(game, fn _html -> has_element?(game, "#memory-draft") end)
      assert has_element?(game, "#draft-accept")
      assert has_element?(game, "#draft-dismiss")
      assert render(element(game, "#memory-draft-moves")) =~ "2... Nf6 3. Nxe5 d6"

      {:ok, round, _html} = live(build_conn(), ~p"/round/1")
      assert has_element?(round, "[id^=tile-draft-]")
    end

    test "dismissed: the game stays as it was, and the same memory does not bring it back",
         %{board: board} do
      {:ok, view, _html} = live(build_conn(), ~p"/round/1/board/1")
      eventually_html(view, fn _html -> has_element?(view, "#memory-draft") end)
      view |> element("#draft-dismiss") |> render_click()

      eventually_html(view, fn _html -> not has_element?(view, "#memory-draft") end)
      assert Games.sans(Games.get(1, 1)) == ~w(e4 e5 Nf3 Nc6)
      assert "draft.dismissed" in log_kinds()

      remember(board, BoardMemory.game(~w(e4 e5 Nf3 Nf6 Nxe5 d6)))
      assert MemoryDrafts.pending(Games.get(1, 1).id) == nil
      refute Boards.snapshot(board.id).draft
    end

    test "accepted: the game is the board's from where they part, and is sent again whole",
         %{board: board} do
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5 Nf3 Nf6 Nxe5 d6))))
      Outbox.drain()
      draft = MemoryDrafts.pending(Games.get(1, 1).id)

      {:ok, view, _html} = live(build_conn(), ~p"/round/1/board/1")
      eventually_html(view, fn _html -> has_element?(view, "#memory-draft") end)
      view |> element("#draft-accept") |> render_click()

      eventually(fn -> sans(board.id) == ~w(e4 e5 Nf3 Nf6 Nxe5 d6) end)
      assert Games.sans(Games.get(1, 1)) == ~w(e4 e5 Nf3 Nf6 Nxe5 d6)
      assert "draft.accepted" in log_kinds()
      eventually_html(view, fn _html -> not has_element?(view, "#memory-draft") end)
      eventually(fn -> Boards.snapshot(board.id).status != :out_of_sync end)
      assert %{status: "accepted"} = MemoryDrafts.get(draft.id)
    end

    test "a draft the game has moved past is not played over moves it never saw",
         %{board: board} do
      draft = MemoryDrafts.pending(Games.get(1, 1).id)
      # The arbiter says Black's first move was another one.
      assert {:ok, _dropped} = Boards.edit(board.id, 2, "c5")
      assert {:error, :overtaken} = Boards.accept_draft(board.id, draft.id)
      assert Enum.take(Games.sans(Games.get(1, 1)), 2) == ~w(e4 c5)
    end
  end

  test "a memory that makes no sense leaves the board and the game as they were" do
    board = board_on(1)
    play_on("FAKE1", board.id, ~w(e4 e5))
    pid = BoardServer.whereis(board.id)

    remember(board, [:power_up, {:field, 99, nil}, "nonsense", {:clock, :green, -5}, nil])
    remember(board, [:start_position, {:field, 12, {:w, :k}}, {:field, 12, nil}])

    assert BoardServer.whereis(board.id) == pid
    assert Games.sans(Games.get(1, 1)) == ~w(e4 e5)
    play_on("FAKE1", board.id, ~w(Nf3), ~w(e4 e5))
    assert Games.sans(Games.get(1, 1)) == ~w(e4 e5 Nf3)
  end
end
