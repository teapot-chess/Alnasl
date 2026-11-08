defmodule Alnasl.LiveBoardControlTest do
  @moduledoc """
  Live board control (board link revision 2), end to end against the fake
  pairing program and an emulated DGT board: the arbiter asks something of
  a board in OpenPairings (or Manubrium), the box fetches it, carries it
  out once, writes it down and answers; and the box tells the pairing
  program what its boards show.
  """

  use Alnasl.HallCase

  import Alnasl.LinkHelpers

  alias Alnasl.{BoardMemory, BoardServer, FakeOpenPairings, MemoryDrafts, Tables, Tournaments}
  alias Alnasl.OpenPairings.{Commands, RemoteCommand, TablesReporter}

  setup do
    pairing_program()
    open = linked(17, name: "Open", boards: 2)
    board = fake_dgt("FAKE1")
    {:ok, board} = Tables.set_table(board, 1)
    {:ok, _} = Tournaments.assign_tables(open, 1, 2)
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    eventually(fn -> Boards.snapshot(board.id).white == "IM Open Player 1" end)
    {:ok, open: open, board: Boards.get!(board.id)}
  end

  # The arbiter's tap, the box's next poll, and what the box answered.
  defp command(board, kind, args \\ %{}, game \\ nil, tournament \\ 17) do
    n = FakeOpenPairings.command(tournament, board_id(board), kind, args, game)
    {n, carry_out(n)}
  end

  defp carry_out(n) do
    poll()
    link = Tournaments.link_of(by_remote(17))
    assert link.commands >= 1 and link.revision == 2
    assert :ok = Commands.run(link)
    FakeOpenPairings.command(n)["answer"]
  end

  defp board_id(%{id: id}), do: id
  defp board_id(id) when is_integer(id), do: id

  defp count(kind), do: Enum.count(log_kinds(), &(&1 == kind))

  describe "commands" do
    test "flip: the board is read the other way up, written down and answered", %{board: board} do
      assert {n, %{"status" => "done"}} = command(board, "flip", %{"flipped" => true})
      assert Boards.get!(board.id).flipped
      assert FakeOpenPairings.command(n)["state"] == "done"

      assert %RemoteCommand{status: "done", kind: "flip"} =
               Repo.get_by(RemoteCommand, remote_id: n)

      assert count("command.done") == 1

      [event | _] = Alnasl.Log.list(kind: "command.done")
      assert Jason.decode!(event.data)["by"] == "arbiter via OpenPairings"
      assert event.board_id == board.id
    end

    test "a command fetched again is answered again, and not carried out twice", %{board: board} do
      {n, %{"status" => "done"}} = command(board, "flip", %{"flipped" => true})
      # The arbiter turns it back on the box; the answer was lost on the way.
      :ok = Boards.flip(board, false)
      FakeOpenPairings.unanswer(n)

      assert carry_out(n) == %{"status" => "done"}
      refute Boards.get!(board.id).flipped
      assert count("command.done") == 1
    end

    test "takeback: the last moves go", %{board: board} do
      play_on("FAKE1", board.id, ~w(e4 e5 Nf3))
      assert {_n, %{"status" => "done"}} = command(board, "takeback", %{"plies" => 2})
      assert sans(board.id) == ~w(e4)
    end

    test "set_position: the game starts from it; a position that is none is refused",
         %{board: board} do
      fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
      assert {_n, %{"status" => "done"}} = command(board, "set_position", %{"fen" => fen})
      assert Boards.snapshot(board.id).start_fen == fen

      assert {_n, %{"status" => "failed", "error" => "bad_position"}} =
               command(board, "set_position", %{"fen" => "not a position"})

      assert count("command.failed") == 1
    end

    test "unlink and link: the board feeds another board of the round", %{board: board} do
      assert {_n, %{"status" => "done"}} = command(board, "unlink")
      assert Boards.get!(board.id).round == nil

      assert {_n, %{"status" => "done"}} =
               command(board, "link", %{"round" => 1, "board_no" => 2})

      assert %{round: 1, board_no: 2} = Boards.get!(board.id)
      eventually(fn -> Boards.snapshot(board.id).white == "Open Player 3" end)
    end

    test "finish: the game is over on the box, the tournament's result is not touched",
         %{board: board, open: open} do
      play_on("FAKE1", board.id, ~w(e4 e5))

      assert {_n, %{"status" => "done"}} =
               command(board, "finish", %{"result" => "1-0"}, "g17r1b1s0")

      game = Games.current(open.id, 1, 1)
      assert game.status == "finished" and game.result == "1-0"

      results =
        for round <- FakeOpenPairings.document(17)["rounds"],
            b <- round["boards"],
            do: b["result"]

      assert Enum.all?(results, &is_nil/1)
    end

    test "restart and resync", %{board: board} do
      pid = BoardServer.whereis(board.id)
      assert {_n, %{"status" => "done"}} = command(board, "restart")
      eventually(fn -> BoardServer.whereis(board.id) not in [nil, pid] end)
      eventually(fn -> Boards.snapshot(board.id).connected? end)

      assert {_n, %{"status" => "done"}} = command(board, "resync")
    end

    test "what the box does not know, or may not touch, is refused by name",
         %{board: board} do
      assert {_n, %{"status" => "failed", "error" => "unknown_kind"}} =
               command(board, "self_destruct")

      assert {_n, %{"status" => "failed", "error" => "wrong_game"}} =
               command(board, "flip", %{"flipped" => true}, "g17r1b2s0")

      refute Boards.get!(board.id).flipped

      assert {_n, %{"status" => "failed", "error" => "no_board"}} =
               command(99_999, "flip", %{"flipped" => true})

      assert {_n, %{"status" => "failed", "error" => "bad_args"}} =
               command(board, "takeback", %{"plies" => 50})

      # A board of the box's own tournament is not this code's to steer.
      {:ok, other} =
        Boards.create(%{
          name: "Elsewhere",
          driver: "simulator",
          port: "sim-elsewhere",
          enabled: false,
          tournament_id: own().id
        })

      assert {_n, %{"status" => "failed", "error" => "other_tournament"}} =
               command(other, "flip", %{"flipped" => true})

      {:ok, _} = Boards.unlink(board)

      assert {_n, %{"status" => "failed", "error" => "no_game"}} =
               command(board, "takeback", %{"plies" => 1})

      assert count("command.failed") == 6
    end

    test "nothing is fetched while nothing waits, nor from an OpenPairings without commands",
         %{open: open} do
      link = Tournaments.link_of(open)
      assert Commands.run(link) == :skipped
      assert FakeOpenPairings.requests("GET", "/commands") == []

      FakeOpenPairings.revision(nil)
      Tournaments.get_link(link.id) |> Ecto.Changeset.change(etag: nil) |> Repo.update!()
      poll()
      link = Tournaments.link_of(open)
      assert link.revision == nil
      refute Alnasl.OpenPairings.controls?(link)
      assert Commands.run(%{link | commands: 3}) == :skipped
    end
  end

  describe "guessed moves" do
    # A game whose last moves were guessed, on the board, linked to board 2.
    defp guessed(board, open, sans, guessed?) do
      {:ok, board} = Boards.unlink(board)
      pairing = Tournaments.board(open.id, 1, 2)
      game = Games.ensure(open.id, 1, 2, Games.pairing_attrs(pairing))

      plies =
        sans
        |> Enum.with_index()
        |> Enum.map(fn {san, i} ->
          %{san: san, flags: if(guessed?.(i), do: [:guessed, :alone], else: []), clock: nil}
        end)

      Games.apply_event(game, {:moves, plies}, System.os_time(:millisecond))
      set_pieces("FAKE1", List.last(boards_after(sans)))

      eventually(fn ->
        Boards.snapshot(board.id).raw == Position.to_text(List.last(boards_after(sans)))
      end)

      {:ok, board} = Boards.link(board, 1, 2)
      eventually(fn -> Boards.snapshot(board.id).status in [:live, :recovered] end)
      board
    end

    test "confirm: the guessed moves are kept, as the arbiter's", %{board: board, open: open} do
      board = guessed(board, open, ~w(e4 e5 Nf3 Nc6), &(&1 >= 2))
      assert TablesReporter.table(board)["guessed_plies"] == [3, 4]
      assert TablesReporter.table(board)["state"] == "guessed"

      assert {_n, %{"status" => "done"}} = command(board, "confirm_guess", %{"ply" => 4})
      assert sans(board.id) == ~w(e4 e5 Nf3 Nc6)
      assert Enum.all?(Enum.drop(Boards.snapshot(board.id).plies, 2), &(&1.flags == [:arbiter]))

      assert {_n, %{"status" => "failed", "error" => "not_guessed"}} =
               command(board, "confirm_guess", %{"ply" => 4})
    end

    test "reject: the guessed moves are taken back", %{board: board, open: open} do
      board = guessed(board, open, ~w(e4 e5 Nf3 Nc6), &(&1 >= 2))
      assert {_n, %{"status" => "done"}} = command(board, "reject_guess", %{"ply" => 3})
      assert sans(board.id) == ~w(e4 e5)
    end

    test "reject: not when moves were played on top of them", %{board: board, open: open} do
      board = guessed(board, open, ~w(e4 e5 Nf3 Nc6 Bb5 a6), &(&1 in [2, 3]))

      assert {_n, %{"status" => "failed", "error" => "not_last"}} =
               command(board, "reject_guess", %{"ply" => 3})

      assert length(sans(board.id)) == 6
    end
  end

  describe "the board's memory" do
    setup %{board: board} do
      play_on("FAKE1", board.id, ~w(e4 e5 Nf3 Nc6))
      pid = BoardServer.whereis(board.id)

      send(
        pid,
        {:driver, board.id, {:history, BoardMemory.game(~w(e4 e5 Nf3 Nf6 Nxe5 d6))}}
      )

      :ok = BoardServer.sync(pid)
      draft = eventually(fn -> Boards.snapshot(board.id).draft end)
      {:ok, draft: draft}
    end

    test "the draft is in the tables; dismissed from afar, it stays dismissed",
         %{board: board, draft: draft, open: open} do
      assert %{"id" => id, "reason" => "conflict", "from_ply" => 3} =
               TablesReporter.table(board)["draft"]

      assert id == draft.id

      assert {_n, %{"status" => "done"}} = command(board, "dismiss_draft", %{"draft" => draft.id})
      assert %{status: "dismissed"} = MemoryDrafts.get(draft.id)
      assert Games.sans(Games.current(open.id, 1, 1)) == ~w(e4 e5 Nf3 Nc6)

      assert {_n, %{"status" => "failed", "error" => "no_draft"}} =
               command(board, "accept_draft", %{"draft" => draft.id})
    end

    test "accepted from afar: the game is the board's", %{board: board, draft: draft, open: open} do
      set_pieces("FAKE1", List.last(boards_after(~w(e4 e5 Nf3 Nf6 Nxe5 d6))))
      assert {_n, %{"status" => "done"}} = command(board, "accept_draft", %{"draft" => draft.id})
      assert Games.sans(Games.current(open.id, 1, 1)) == ~w(e4 e5 Nf3 Nf6 Nxe5 d6)
    end
  end

  describe "the tables" do
    setup do
      start_supervised!({TablesReporter, tick: false})
      :ok
    end

    test "every board of the tournament, as it stands", %{board: board} do
      play_on("FAKE1", board.id, ~w(e4 e5))
      :ok = TablesReporter.report_now()

      assert [table] = FakeOpenPairings.tables(17)

      assert %{
               "board" => id,
               "game" => "g17r1b1s0",
               "round" => 1,
               "board_no" => 1,
               "table" => 1,
               "connected" => true,
               "state" => "live",
               "flipped" => false,
               "alarms" => [],
               "draft" => nil,
               "guessed_plies" => [],
               "last_move" => "e7e5"
             } = table

      assert id == board.id
      assert table["fen"] =~ ~r{^rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w}
    end

    test "an unlinked board is a table with no game", %{board: board} do
      {:ok, _} = Boards.unlink(board)
      eventually(fn -> Boards.snapshot(board.id).status == :unlinked end)
      :ok = TablesReporter.report_now()

      assert [%{"game" => nil, "state" => "unlinked", "round" => nil}] =
               FakeOpenPairings.tables(17)
    end

    test "an OpenPairings from before revision 2 is sent none", %{open: open} do
      FakeOpenPairings.revision(nil)
      Tournaments.link_of(open) |> Ecto.Changeset.change(etag: nil) |> Repo.update!()
      poll()
      :ok = TablesReporter.report_now()
      assert FakeOpenPairings.tables(17) == nil
      assert FakeOpenPairings.requests("POST", "/tables") == []
    end
  end
end
