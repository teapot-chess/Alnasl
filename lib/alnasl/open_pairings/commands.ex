defmodule Alnasl.OpenPairings.Commands do
  @moduledoc """
  What an arbiter asks of this box's boards from OpenPairings (and from
  Manubrium, the phone app, through it): board link revision 2, `GET
  /commands` and `POST /commands/:id` in `docs/board-link-api.md` there.

  The box always calls. When the link's listing says commands wait
  (`commands > 0`), the poller asks for them (`run/1`), and each is carried
  out here against `Alnasl.Boards`, exactly as the same button on the
  board's page would, then answered.

  ## Once, and only once

  The pairing program hands a command out until it is answered, so a box
  that fell over in between gets it again. Each outcome is written down by
  link and command id (`Alnasl.OpenPairings.RemoteCommand`) *before* the
  answer goes out; a command the box has met before is answered again with
  what was written, and not carried out a second time. Rows older than a
  day are dropped: a command expires after two minutes.

  ## What a command may touch

  `tournament` is the pairing program's id of one of this link's
  tournaments, `board` this box's id of a physical board, and the board
  must be playing in that tournament (`other_tournament` otherwise: a code
  for one tournament does not steer another's boards). When `game` is
  given, the board must still be feeding that game (`wrong_game`): the
  arbiter decided on what he saw, and the hall may have moved on since.

  ## What it never does

  Enter a result. `finish` closes the game *on the box*
  (`Alnasl.Boards.set_result/2`), and what the board saw goes back to the
  pairing program as a report like any other; the tournament's result is
  the arbiter's, entered there.

  Every command is in the log, done or not: `command.done`,
  `command.failed`, with who asked - "arbiter via OpenPairings".
  """

  import Ecto.Query

  require Logger

  alias Alnasl.{Boards, Chess, Games, Log, Repo, Tournaments}
  alias Alnasl.Boards.Board
  alias Alnasl.OpenPairings.{Client, RemoteCommand}
  alias Alnasl.Tournaments.{Link, Tournament}

  @by "arbiter via OpenPairings"
  @kinds ~w(confirm_guess reject_guess accept_draft dismiss_draft set_position takeback flip
            link unlink restart resync finish)
  # The kinds that work on the game a board feeds, and need its process.
  @on_the_game ~w(confirm_guess reject_guess accept_draft dismiss_draft set_position takeback
                  finish)
  @keep_days 1

  def kinds, do: @kinds

  @doc """
  Fetches the commands waiting for `link` and carries out, answers or
  answers again each. `:ok`, `:skipped` (the pairing program is older than
  revision 2, or says nothing waits), or `{:error, reason}` when the list
  could not be had.
  """
  def run(%Link{commands: waiting} = link) do
    if Alnasl.OpenPairings.controls?(link) and is_integer(waiting) and waiting > 0,
      do: fetch_and_run(link),
      else: :skipped
  end

  defp fetch_and_run(link) do
    case Client.commands(link) do
      {:ok, commands} ->
        prune()
        Enum.each(commands, &handle(link, &1))
        :ok

      # An OpenPairings that lists commands and has no `/commands`: not
      # worth a word in the arbiter's log, nor a crash.
      {:error, :not_the_api} ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  One command, from the list: carried out (the first time) and answered.
  Returns the outcome sent, `%{"status" => ...}`.
  """
  def handle(%Link{} = link, %{"id" => id} = command) when is_integer(id) do
    outcome =
      case claim(link, command) do
        {:known, %RemoteCommand{status: "pending"} = row} ->
          # Written down and never finished: the box fell over somewhere
          # between starting and noting the outcome. Whether it happened is
          # unknown, so it is not done again; the arbiter asks afresh.
          settle(
            row,
            command,
            {:error, "failed", "the box was interrupted; look at the board"}
          )

        {:known, row} ->
          row

        {:won, row} ->
          result =
            try do
              execute(link, command)
            rescue
              error ->
                Logger.error("command #{id} crashed: " <> Exception.message(error))
                {:error, "failed", "the box could not carry it out"}
            catch
              :exit, _reason -> {:error, "failed", "the board did not answer"}
            end

          settle(row, command, result)
      end

    answer = outcome(outcome)

    case Client.answer(link, id, answer) do
      {:ok, _state} -> mark_answered(outcome)
      {:error, :command_not_found} -> mark_answered(outcome)
      # Asked again with the next poll: the command is still listed.
      {:error, _reason} -> :ok
    end

    answer
  end

  def handle(_link, _not_a_command), do: nil

  # Writes the command down as `pending` *before* anything is carried out.
  # Whoever inserts the row carries the command out; anyone else finds it.
  defp claim(link, command) do
    kind = command["kind"]

    %RemoteCommand{
      link_id: link.id,
      remote_id: command["id"],
      kind: text(kind, 32) || "?",
      board_id: if(is_integer(command["board"]), do: command["board"]),
      status: "pending"
    }
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:link_id, :remote_id])
    |> case do
      {:ok, %RemoteCommand{id: nil}} ->
        {:known, Repo.get_by!(RemoteCommand, link_id: link.id, remote_id: command["id"])}

      {:ok, row} ->
        {:won, row}
    end
  end

  # Notes how it went, in the row and in the log.
  defp settle(%RemoteCommand{} = row, command, result) do
    {status, error, detail} =
      case result do
        :ok -> {"done", nil, nil}
        {:error, code, detail} -> {"failed", code, String.slice(detail, 0, 200)}
      end

    kind = command["kind"]
    board_id = if is_integer(command["board"]), do: command["board"]
    board = board_id && Boards.get(board_id)

    ref =
      if board,
        do: %{board_id: board.id, round: board.round, board_no: board.board_no},
        else: %{}

    data = %{kind: text(kind, 32), board: board_id, command: command["id"], by: @by}

    case status do
      "done" ->
        Log.add(:info, "command.done", data, ref)

      "failed" ->
        Log.add(:warn, "command.failed", Map.merge(data, %{error: error, detail: detail}), ref)
    end

    row |> Ecto.Changeset.change(status: status, error: error, detail: detail) |> Repo.update!()
  end

  defp outcome(%RemoteCommand{status: "done"}), do: %{"status" => "done"}

  defp outcome(%RemoteCommand{error: error, detail: detail}) do
    %{"status" => "failed", "error" => error || "failed"}
    |> then(&if(detail, do: Map.put(&1, "detail", detail), else: &1))
  end

  defp mark_answered(%RemoteCommand{answered_at: nil} = row) do
    row |> Ecto.Changeset.change(answered_at: DateTime.utc_now(:second)) |> Repo.update!()
    :ok
  end

  defp mark_answered(_row), do: :ok

  defp prune do
    before = DateTime.add(DateTime.utc_now(:second), -@keep_days * 86_400, :second)
    Repo.delete_all(from(c in RemoteCommand, where: c.inserted_at < ^before))
  end

  @doc "Forgets what was carried out through a link (it was removed)."
  def forget(%Link{id: id}),
    do: Repo.delete_all(from(c in RemoteCommand, where: c.link_id == ^id))

  defp text(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp text(_other, _max), do: nil

  # --- carrying one out --------------------------------------------------------

  @doc """
  Carries out one command. `:ok` or `{:error, code, detail}` with a code of
  the contract (`no_board`, `not_running`, `no_game`, `wrong_game`,
  `no_draft`, `not_guessed`, `not_last`, `bad_position`, `bad_args`,
  `refused`, `other_tournament`, `unknown_kind`, `failed`).
  """
  def execute(%Link{} = link, command) do
    kind = command["kind"]
    args = if is_map(command["args"]), do: command["args"], else: %{}

    with :ok <- known(kind),
         {:ok, tournament} <- tournament(link, command["tournament"]),
         {:ok, board} <- board(command["board"], tournament),
         :ok <- same_game(board, command["game"]),
         :ok <- ready(board, kind) do
      run(kind, board, tournament, args)
    end
  end

  defp known(kind) when kind in @kinds, do: :ok

  defp known(kind),
    do: {:error, "unknown_kind", "this box does not know #{inspect(kind)}"}

  defp tournament(%Link{} = link, remote_id) when is_integer(remote_id) do
    held =
      Enum.find(Tournaments.of_link(link), &(&1.remote_id == remote_id)) ||
        through_another_code(link, remote_id)

    case held do
      %Tournament{} = tournament -> {:ok, tournament}
      nil -> {:error, "other_tournament", "this code does not reach that tournament here"}
    end
  end

  defp tournament(_link, _other), do: {:error, "bad_args", "tournament: an id"}

  # One tournament reached through two codes is one row, on one of them
  # (`Alnasl.OpenPairings.Duplicates`): a command that came through the
  # other code is for that row all the same, as long as it is the same
  # pairing program.
  defp through_another_code(link, remote_id) do
    for other <- Tournaments.links(),
        other.id != link.id,
        other.root == link.root,
        tournament <- Tournaments.of_link(other),
        tournament.remote_id == remote_id,
        not tournament.gone do
      tournament
    end
    |> List.first()
  end

  defp board(id, tournament) when is_integer(id) do
    case Boards.get(id) do
      nil ->
        {:error, "no_board", "this box has no board #{id}"}

      %Board{tournament_id: tid} = board when tid == tournament.id ->
        {:ok, board}

      %Board{} ->
        {:error, "other_tournament", "the board plays in another tournament on this box"}
    end
  end

  defp board(_other, _tournament), do: {:error, "bad_args", "board: an id"}

  # The game the board feeds now, as the pairing program names it.
  @doc false
  def feeding(%Board{} = board) do
    case Boards.snapshot(board) do
      %{game_id: id} when is_integer(id) ->
        case Repo.get(Games.Game, id) do
          %Games.Game{local: false} = game -> game
          _kept_here -> nil
        end

      _no_game ->
        nil
    end
  end

  defp same_game(_board, nil), do: :ok

  defp same_game(board, game) when is_binary(game) do
    case feeding(board) do
      %Games.Game{remote_game: ^game} -> :ok
      _other -> {:error, "wrong_game", "the board no longer feeds that game"}
    end
  end

  defp same_game(_board, _other), do: {:error, "bad_args", "game: an id or null"}

  defp ready(%Board{} = board, kind) when kind in @on_the_game do
    cond do
      board.round == nil or board.board_no == nil ->
        {:error, "no_game", "the board feeds no game"}

      not Boards.running?(board.id) ->
        {:error, "not_running", "the board is not connected on the box"}

      true ->
        :ok
    end
  end

  defp ready(_board, _kind), do: :ok

  defp run("flip", board, _tournament, %{"flipped" => flipped}) when is_boolean(flipped) do
    case Boards.flip(board, flipped) do
      :ok ->
        :ok

      # Not running: the row says it, and the board is read that way when
      # it is connected again - as the board page leaves it.
      {:error, :not_running} ->
        board |> Board.changeset(%{flipped: flipped}) |> Repo.update!()
        Log.add(:info, "board.flipped", %{flipped: flipped, auto: false}, %{board_id: board.id})
        Phoenix.PubSub.broadcast(Alnasl.PubSub, "boards", {:board, board.id})
        :ok

      other ->
        failed(other)
    end
  end

  defp run("link", board, _tournament, %{"round" => round, "board_no" => no})
       when is_integer(round) and round in 1..999 and is_integer(no) and no in 1..9999 do
    case Boards.link(board, round, no) do
      {:ok, _board} -> :ok
      other -> failed(other)
    end
  end

  defp run("unlink", %Board{round: nil}, _tournament, _args), do: :ok

  defp run("unlink", board, _tournament, _args) do
    case Boards.unlink(board) do
      {:ok, _board} -> :ok
      other -> failed(other)
    end
  end

  defp run("restart", %Board{enabled: false}, _tournament, _args),
    do: {:error, "not_running", "the board is switched off on the box"}

  # The driver starts again; a driver that reads the board's memory asks
  # it again when the board answers.
  defp run("restart", board, _tournament, _args) do
    case Boards.restart(board) do
      {:ok, _pid} -> :ok
      {:error, :standing_by} -> {:error, "refused", "this box is standing by for another"}
      {:error, :no_local_boards} -> {:error, "refused", "this box reads no boards of its own"}
      other -> failed(other)
    end
  end

  defp run("resync", board, _tournament, _args) do
    case Boards.resync(board.id) do
      {:ok, _outcome} -> :ok
      {:error, :not_running} -> {:error, "not_running", "the board is not connected on the box"}
      {:error, :not_linked} -> {:error, "no_game", "the board feeds no game"}
      other -> failed(other)
    end
  end

  defp run("takeback", board, _tournament, %{"plies" => n}) when is_integer(n) and n in 1..20 do
    case Boards.snapshot(board) do
      %{plies: [_ | _] = plies} ->
        for _ <- 1..min(n, length(plies)), do: Boards.undo(board.id)
        :ok

      _none ->
        {:error, "refused", "the game has no moves to take back"}
    end
  end

  defp run("set_position", board, _tournament, %{"fen" => fen}) when is_binary(fen) do
    with {:ok, _pos} <- Chess.parse_fen(fen),
         {:ok, _state} <- Boards.set_fen(board.id, fen) |> ok() do
      :ok
    else
      {:error, :not_running} -> {:error, "not_running", "the board is not connected on the box"}
      {:error, :not_linked} -> {:error, "no_game", "the board feeds no game"}
      {:error, message} when is_binary(message) -> {:error, "bad_position", message}
      _other -> {:error, "bad_position", "not a position this game can take"}
    end
  end

  defp run("finish", board, _tournament, %{"result" => result})
       when result in ["1-0", "0-1", "1/2-1/2", "*"] do
    board.id |> Boards.set_result(result) |> done()
  end

  defp run("accept_draft", board, _tournament, %{"draft" => draft}) when is_integer(draft) do
    case Boards.accept_draft(board.id, draft) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, :no_draft} ->
        {:error, "no_draft", "no such draft waits on this game"}

      {:error, :overtaken} ->
        {:error, "refused", "the game has moved on since the draft was made"}

      other ->
        failed(other)
    end
  end

  defp run("dismiss_draft", board, _tournament, %{"draft" => draft}) when is_integer(draft) do
    case Boards.dismiss_draft(board.id, draft) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :no_draft} -> {:error, "no_draft", "no such draft waits on this game"}
      other -> failed(other)
    end
  end

  # "Keep it": the moves the box guessed are the ones it keeps, now as the
  # arbiter's.
  defp run("confirm_guess", board, _tournament, %{"ply" => ply})
       when is_integer(ply) and ply >= 1 do
    case Boards.alternatives(board.id, ply) do
      %{current: current} ->
        case Boards.choose(board.id, ply, current) do
          {:ok, _dropped} -> :ok
          {:error, message} when is_binary(message) -> {:error, "refused", message}
          other -> failed(other)
        end

      {:error, :not_running} ->
        {:error, "not_running", "the board is not connected on the box"}

      _not_marked ->
        {:error, "not_guessed", "move #{ply} is not a guessed move"}
    end
  end

  # The guessed run around the ply is taken back, when it is the end of
  # the game: the moves after it were played on top of it.
  defp run("reject_guess", board, _tournament, %{"ply" => ply})
       when is_integer(ply) and ply >= 1 do
    case Boards.alternatives(board.id, ply) do
      %{from: from, to: to} ->
        plies = length(Boards.snapshot(board)[:plies] || [])

        if to == plies do
          for _ <- from..to, do: Boards.undo(board.id)
          :ok
        else
          {:error, "not_last", "the guessed moves are not the last ones"}
        end

      {:error, :not_running} ->
        {:error, "not_running", "the board is not connected on the box"}

      _not_marked ->
        {:error, "not_guessed", "move #{ply} is not a guessed move"}
    end
  end

  defp run(kind, _board, _tournament, _args),
    do: {:error, "bad_args", "these are not the arguments of #{kind}"}

  defp ok(:ok), do: {:ok, nil}
  defp ok(other), do: other

  defp done(:ok), do: :ok
  defp done({:ok, _}), do: :ok
  defp done(other), do: failed(other)

  defp failed({:error, :not_running}),
    do: {:error, "not_running", "the board is not connected on the box"}

  defp failed({:error, :not_linked}), do: {:error, "no_game", "the board feeds no game"}

  defp failed({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, "bad_args", inspect(changeset.errors)}

  defp failed({:error, reason}) when is_binary(reason), do: {:error, "refused", reason}
  defp failed({:error, reason}), do: {:error, "refused", inspect(reason)}
  defp failed(other), do: {:error, "failed", inspect(other)}
end
