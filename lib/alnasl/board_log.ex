defmodule Alnasl.BoardLog do
  @moduledoc """
  The board's debug log: everything one board went through lately, in the
  order it happened. Pieces lifted and set down, the move the tracker made
  of them and on what grounds, the clock pressed, the result and exactly
  why, what was queued and what each destination said back.

  Where `Alnasl.Log` is the arbiter's log (what happened, kept in the
  database), this is the mechanic's: in memory, the newest #{500} lines a
  board, gone with a restart. The arbiter's lines about a board are copied
  in as they are written (`mirror/1`), so the two never contradict each
  other and the arbiter's log is not written twice.

  Shown beside the board on its page when Setup > Advanced has "Board debug
  log" on (`enabled?/0`), to whoever may arbitrate there. The ring is kept
  whether that is on or not: a line costs one ETS insert, and turning the
  log on in the middle of a mystery should show the mystery, not start
  watching from then on.

  A line is `%{id, at, cat, kind, data, tech, level}`: `cat` is one of
  #{inspect(~w(connection position move clock result sent other)a)}, `kind`
  says which sentence it is (made where it is shown, in the reader's
  language: `AlnaslWeb.BoardLogWords`), `data` its facts, `tech` what a
  person who knows DGT boards wants to see (bytes, FEN, squares), never
  translated.
  """

  use GenServer

  @table :alnasl_board_log
  @counts :alnasl_board_log_counts
  @keep 500
  # Trimmed in steps, not at every line.
  @slack 50

  @cats ~w(connection position move clock result sent other)a

  def cats, do: @cats
  def keep, do: @keep

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:ordered_set, :public, :named_table, write_concurrency: true])
    :ets.new(@counts, [:set, :public, :named_table, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Whether the log is shown (Setup > Advanced > Board debug log)."
  def enabled?, do: Alnasl.Settings.get("board_debug_log") == true

  def topic(board_id), do: "board_log:#{board_id}"
  def subscribe(board_id), do: Phoenix.PubSub.subscribe(Alnasl.PubSub, topic(board_id))
  def unsubscribe(board_id), do: Phoenix.PubSub.unsubscribe(Alnasl.PubSub, topic(board_id))

  @doc """
  Writes a line about board `board_id`. Never raises: a log that cannot be
  written is not a reason for a board to stop.
  """
  def add(board_id, cat, kind, data \\ %{}, tech \\ nil, level \\ :info)

  def add(board_id, cat, kind, data, tech, level)
      when is_integer(board_id) and cat in @cats do
    id = System.unique_integer([:monotonic, :positive])

    entry = %{
      id: id,
      at: DateTime.utc_now(),
      cat: cat,
      kind: to_string(kind),
      data: data,
      tech: tech,
      level: level
    }

    :ets.insert(@table, {{board_id, id}, entry})
    count = :ets.update_counter(@counts, board_id, 1, {board_id, 0})
    if count > @keep + @slack, do: trim(board_id, count - @keep)
    Phoenix.PubSub.broadcast(Alnasl.PubSub, topic(board_id), {:board_log, board_id, entry})
    entry
  rescue
    ArgumentError -> nil
  end

  def add(_board_id, _cat, _kind, _data, _tech, _level), do: nil

  @doc """
  Copies a line of the arbiter's log that is about a board (`Alnasl.Log.add/4`).
  Its words are the arbiter's log's own (`AlnaslWeb.Words.log/1`).
  """
  def mirror(%Alnasl.Log.Event{board_id: board_id, kind: kind} = event)
      when is_integer(board_id) do
    add(board_id, cat_of(kind), "log", %{event: event}, nil, String.to_existing_atom(event.level))
  end

  def mirror(_event), do: nil

  @doc "Which category a kind of the arbiter's log falls in."
  def cat_of("board." <> _), do: :connection
  def cat_of("loop." <> _), do: :connection
  def cat_of("bridge." <> _), do: :connection
  def cat_of("move." <> _), do: :move
  def cat_of("piece." <> _), do: :move
  def cat_of("square." <> _), do: :move
  def cat_of("repair." <> _), do: :move
  def cat_of("clock." <> _), do: :clock
  def cat_of("result." <> _), do: :result
  def cat_of("draft." <> _), do: :result
  def cat_of("outbox." <> _), do: :sent
  def cat_of("destination." <> _), do: :sent
  def cat_of(_other), do: :other

  @doc """
  A line about the game on board `board_no` of `round` of a tournament: on
  every board that feeds it (usually one, sometimes none).
  """
  def for_game(
        tournament_id,
        round,
        board_no,
        cat,
        kind,
        data \\ %{},
        tech \\ nil,
        level \\ :info
      ) do
    for board <- boards(tournament_id, round, board_no),
        do: add(board.id, cat, kind, data, tech, level)

    :ok
  rescue
    _error -> :ok
  end

  defp boards(tournament_id, round, board_no)
       when is_integer(round) and is_integer(board_no) do
    import Ecto.Query

    Alnasl.Boards.Board
    |> where([b], b.round == ^round and b.board_no == ^board_no)
    |> where([b], b.tournament_id == ^tournament_id)
    |> select([b], %{id: b.id})
    |> Alnasl.Repo.all()
  end

  defp boards(_tournament_id, _round, _board_no), do: []

  @doc "The lines of a board, newest first, at most `limit`."
  def list(board_id, limit \\ @keep) when is_integer(board_id) do
    case :ets.select_reverse(@table, [{{{board_id, :_}, :"$1"}, [], [:"$1"]}], limit) do
      {entries, _continuation} -> entries
      :"$end_of_table" -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Forgets a board's lines (the board was removed)."
  def clear(board_id) do
    :ets.match_delete(@table, {{board_id, :_}, :_})
    :ets.delete(@counts, board_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets every board's lines."
  def clear_all do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@counts)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp trim(board_id, n) do
    case :ets.select(@table, [{{{board_id, :"$1"}, :_}, [], [:"$1"]}], n) do
      {ids, _continuation} ->
        for id <- ids, do: :ets.delete(@table, {board_id, id})
        :ets.update_counter(@counts, board_id, -length(ids))

      :"$end_of_table" ->
        :ok
    end
  end
end
