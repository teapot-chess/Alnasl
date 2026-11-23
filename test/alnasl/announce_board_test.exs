defmodule Alnasl.AnnounceBoardTest do
  @moduledoc """
  A board linked to a game of a tournament with a results page is reported
  there at once, as an empty game, so the results site lists the hall's
  boards and not every board of the round. Once a game; never for a game
  that stays on the box, is paused, or belongs to the box's own tournament.
  """

  use Alnasl.HallCase

  import Alnasl.LinkHelpers

  alias Alnasl.{Outbox, Tables, Tournaments}
  alias Alnasl.Outbox.Entry

  setup do
    pairing_program()
    open = linked(17, name: "Open", boards: 2)
    {:ok, open: open}
  end

  defp queued(game) do
    Repo.all(from e in Entry, where: e.game_id == ^game.id, order_by: e.id)
  end

  defp on_table_one(open) do
    board = fake_dgt("FAKE1")
    {:ok, board} = Tables.set_table(board, 1)
    {:ok, _} = Tournaments.assign_tables(open, 1, 2)
    eventually(fn -> Boards.snapshot(board.id).white == "IM Open Player 1" end)
    board
  end

  test "a linked board is announced with an empty game, once", %{open: open} do
    board = on_table_one(open)
    game = Games.current(open.id, 1, 1)

    assert [entry] = queued(game)
    assert entry.plies == 0 and not entry.replace
    body = Jason.decode!(entry.body)
    assert body["moves"] == [] and body["start_fen"] == Alnasl.Chess.start_fen()
    assert {body["round"], body["board"]} == {1, 1}

    # A restart of the board's process links the same game again: no second word.
    Boards.restart(Boards.get!(board.id))
    eventually(fn -> Boards.snapshot(board.id).white == "IM Open Player 1" end)
    assert length(queued(game)) == 1

    # The first move goes as it always did.
    play_on("FAKE1", board.id, ~w(e4))
    eventually(fn -> length(queued(game)) == 2 end)
    assert List.last(queued(game)).plies == 1
  end

  test "not for a paused game, a game that stays on the box, or one already begun", %{open: open} do
    game = Games.ensure(open.id, 1, 2, %{})
    Outbox.announce(Games.pause(game, true))
    assert queued(game) == []

    local = game |> Ecto.Changeset.change(local: true) |> Repo.update!()
    Outbox.announce(local)
    assert queued(game) == []

    {begun, false} =
      Games.apply_event(game, {:moves, [%{san: "d4", flags: [], clock: nil}]}, 1_000)

    Outbox.announce(begun)
    assert queued(game) == []
  end

  test "not for the box's own tournament" do
    game = Games.ensure(Tournaments.default_id(), 1, 1, %{})
    Outbox.announce(game)
    assert queued(game) == []
  end

  test "an announcement for a round not yet published does not hold up the queue", %{open: open} do
    game = Games.ensure(open.id, 1, 2, %{})
    Outbox.announce(game)
    assert [_entry] = queued(game)

    Application.put_env(:alnasl, :req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(409, ~s({"error":"board_not_published"}))
      end
    )

    on_exit(fn -> Application.delete_env(:alnasl, :req_options) end)

    assert {:superseded, entry} = Outbox.step(Tournaments.get(open.id))
    assert entry.state == "superseded" and entry.error == "board_not_published"
    assert Outbox.step(Tournaments.get(open.id)) == :empty
  end
end
