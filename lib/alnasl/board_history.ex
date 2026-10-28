defmodule Alnasl.BoardHistory do
  @moduledoc """
  A board's own memory, read back (`{:history, events}` from Arkab's
  drivers: `Arkab.Dgt.Bus.history/1`), held up against the game the box
  has for that board. Pure: no process, no database. `merge/2` says what
  the memory adds; the board's process (`Alnasl.BoardServer`) does it.

  docs/board-memory.md is the same thing for a reader without the code.

  ## What a memory is

  Everything the board wrote down, oldest first: a square that changed
  (`{:field, square, piece}`, squares as the board reads them, a8 = 0), a
  clock time written when the lever went over (`{:clock, side, ms}`), and
  marks: `:power_up` (switched on; every piece it finds follows),
  `:restarted` (the same, by itself), `:start_position` (the starting
  position stood), `:start_position_rotated`, `:empty_board`,
  `:start_mark`, `:end_of_data`.

  It is turned into what a board process would have seen had it been
  listening (`timeline/2`): one whole board after each change, the clock
  presses between them. A power-up's scan of the pieces is one reading,
  not thirty-two. Until the memory says where every piece stood - a
  power-up, or a starting position - its field events say nothing and are
  passed over: that is the front of a memory that went round.

  ## Replayed with the tracker

  The readings are played through `Alnasl.Tracker`, the one that reads the
  live board, a reading every #{600} ms of its time: long enough for each
  move to settle, short enough that half a castle and a pawn waiting for
  its queen are still waited for. So the moves are found exactly as they
  would have been, with the same marks where the tracker had to search.

  ## Merged, never overwritten

  The game the box has is the anchor. Two ways to find it in a memory:

  1. **From the starting position** (a game that began from it). Each
     starting position in the memory begins a line; the newest is played
     out from scratch and compared with the game:
     - the same moves, or fewer of the same: nothing to do;
     - the same moves and more: `{:extend, plies}`, the moves after the
       game's last, each marked `:memory`, with the clock times the board
       wrote. Unless an older line in the memory fits the game as well:
       then it is not clear which game this is, and it is a draft;
     - other moves: a draft, `:conflict`;
     - the newest line is shorter than the game (the pieces were set up
       again): an older line that continues the game is a draft,
       `:earlier_game`. Never taken by itself: an older line may as well
       be yesterday's game with the same opening.
  2. **From the position the box knows last** (a game set up from a FEN,
     or a memory with no starting position in it): the last reading that
     shows the board where the game stands is where the tracker, restored
     with the game, takes over. Failing that, the newest reading that
     shows an earlier position of the game: what follows is a draft,
     `:conflict`. Failing that too, a line from the starting position is
     offered as `:unknown_start`, and with none of those it is
     `{:unmatched, why}`.

  A draft (`{:draft, reason, %{start_fen, from_ply, plies}}`) is the whole
  game as the memory has it; `from_ply` is how many of its first plies are
  the game's own. The arbiter accepts or dismisses it
  (`Alnasl.MemoryDrafts`).

  Idempotent by construction: a memory merged once gives the same game,
  and merged again it is "the same moves". The same draft twice is the
  same draft (`Alnasl.MemoryDrafts.offer/4` keys it).

  ## What is not known

  How much a board holds and what a full one does (see Arkab's
  `Arkab.Dgt.Bus`). A memory that went round and is read back out of
  order would give lines that fit nothing, and those become drafts or
  nothing; a game is only extended by a line that starts exactly where it
  stands and is legal move by move.
  """

  alias Alnasl.{Chess, Position, Tracker}

  @step_ms 600
  # A memory longer than this is not one; only the newest part is read.
  @max_items 20_000
  # How many starting positions back a memory is looked through.
  @max_lines 8

  @type ply :: %{san: String.t(), flags: [atom()], clock: map() | nil}
  @type result ::
          :nothing
          | {:extend, [ply]}
          | {:draft, :conflict | :earlier_game | :ambiguous | :unknown_start,
             %{start_fen: String.t(), from_ply: non_neg_integer(), plies: [ply]}}
          | {:unmatched, atom()}

  @doc """
  What `events` add to the game. Options: `:start_fen` (the game's, `nil`
  for the standard one), `:plies` (the game's, `[%{san, flags, clock}]`),
  `:flipped?` (the board is plugged in turned round), `:tracker` (the
  tracker's settings).
  """
  @spec merge(list(), keyword()) :: result()
  def merge(events, opts) when is_list(events) do
    start_fen = opts[:start_fen] || Chess.start_fen()
    known = opts[:plies] || []
    items = timeline(events, opts[:flipped?] || false)
    tracker_opts = tracker_opts(opts[:tracker] || [], start_fen)

    standard? = start_board(start_fen) == Position.start() and turn(start_fen) == :w

    lines = fn -> lines(items, tracker_opts(opts[:tracker] || [], Chess.start_fen())) end

    cond do
      standard? and Enum.member?(items, :start) -> from_start(lines.(), known)
      true -> from_anchor(items, known, start_fen, tracker_opts, lines)
    end
  end

  def merge(_events, _opts), do: {:unmatched, :not_a_history}

  # --- the timeline ------------------------------------------------------------

  @doc """
  What a board process would have seen: `[{:board, board} | {:clock, side,
  ms} | :start]`, boards as the box reads them (turned round when the
  board is), `:start` where a starting position stood the right way round.
  """
  def timeline(events, flipped?) do
    events
    |> Enum.take(-@max_items)
    |> Enum.reduce(%{board: nil, scan?: false, flipped?: flipped?, out: []}, &step/2)
    |> end_scan()
    |> Map.fetch!(:out)
    |> Enum.reverse()
    |> dedup()
  end

  defp step({:field, square, piece}, %{board: nil} = acc)
       when is_integer(square) and square in 0..63 and (is_nil(piece) or is_tuple(piece)),
       do: acc

  # The scan after a power-up: pieces put on empty squares, one by one. One
  # reading when it is done, not thirty-two.
  defp step({:field, square, piece}, %{scan?: true, board: board} = acc)
       when is_integer(square) and square in 0..63 and is_tuple(piece) and
              elem(board, square) == nil,
       do: %{acc | board: put_elem(board, square, piece)}

  defp step({:field, square, piece}, acc)
       when is_integer(square) and square in 0..63 and (is_nil(piece) or is_tuple(piece)) do
    acc = end_scan(acc)
    emit(%{acc | board: put_elem(acc.board, square, piece)})
  end

  defp step(mark, acc) when mark in [:power_up, :restarted],
    do: %{end_scan(acc) | board: empty(), scan?: true}

  defp step(:empty_board, %{scan?: true} = acc), do: acc
  defp step(:empty_board, acc), do: emit(%{acc | board: empty()})

  defp step(mark, acc) when mark in [:start_position, :start_position_rotated] do
    raw =
      if mark == :start_position, do: Position.start(), else: Position.rotate(Position.start())

    acc = %{end_scan(acc) | board: raw}
    acc = emit(acc)
    if seen(acc) == Position.start(), do: %{acc | out: [:start | acc.out]}, else: acc
  end

  defp step({:clock, side, ms}, acc)
       when side in [:white, :black] and is_integer(ms) and ms >= 0,
       do: %{end_scan(acc) | out: [{:clock, side, ms} | end_scan(acc).out]}

  defp step(_other, acc), do: acc

  defp end_scan(%{scan?: true} = acc), do: emit(%{acc | scan?: false})
  defp end_scan(acc), do: acc

  defp emit(%{board: nil} = acc), do: acc
  defp emit(acc), do: %{acc | out: [{:board, seen(acc)} | acc.out]}

  defp seen(%{flipped?: true, board: board}), do: Position.rotate(board)
  defp seen(%{board: board}), do: board

  defp empty, do: Tuple.duplicate(nil, 64)

  # The same board twice in a row is one reading.
  defp dedup(items) do
    items
    |> Enum.reduce({[], nil}, fn
      {:board, b}, {acc, b} -> {acc, b}
      {:board, b} = item, {acc, _last} -> {[item | acc], b}
      item, {acc, last} -> {[item | acc], last}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # --- 1. from the starting position -------------------------------------------

  # The lines that begin at each starting position, newest first.
  defp lines(items, tracker_opts) do
    starts = for {:start, i} <- Enum.with_index(items), do: i

    starts
    |> Enum.reverse()
    |> Enum.take(@max_lines)
    |> Enum.map(fn i -> play(Tracker.new(tracker_opts), Enum.drop(items, i + 1)) end)
  end

  defp from_start([newest | older], known) do
    sans = sans(known)
    older_fits? = Enum.any?(older, &(compare(sans(&1), sans) in [:extends, :same]))

    case compare(sans(newest), sans) do
      :same ->
        :nothing

      :extends when older_fits? and known != [] ->
        draft(:ambiguous, Chess.start_fen(), newest, known)

      :extends ->
        {:extend, Enum.drop(newest, length(known))}

      :behind ->
        case Enum.find(older, &(known != [] and compare(sans(&1), sans) == :extends)) do
          nil -> :nothing
          line -> draft(:earlier_game, Chess.start_fen(), line, known)
        end

      :conflict ->
        draft(:conflict, Chess.start_fen(), newest, known)
    end
  end

  # --- 2. from the position the box knows --------------------------------------

  defp from_anchor(items, known, start_fen, tracker_opts, lines) do
    case boards(start_fen, sans(known)) do
      nil ->
        {:unmatched, :game_does_not_replay}

      boards ->
        indexed = Enum.with_index(items)
        n = length(known)

        case last_index(indexed, &(&1 == List.last(boards))) do
          nil -> earlier_anchor(indexed, boards, known, start_fen, tracker_opts, lines)
          i -> continue_from(items, i, known, n, start_fen, tracker_opts)
        end
    end
  end

  defp continue_from(items, i, known, n, start_fen, tracker_opts) do
    played = play(restored(tracker_opts, known, items, i), Enum.drop(items, i + 1))

    case compare(sans(played), sans(known)) do
      :extends -> {:extend, Enum.drop(played, n)}
      :conflict -> draft(:conflict, start_fen, played, known)
      _same_or_behind -> :nothing
    end
  end

  # The newest reading that shows a position the game passed through: the
  # board went another way from there.
  defp earlier_anchor(indexed, boards, known, start_fen, tracker_opts, lines) do
    by_board = boards |> Enum.with_index() |> Map.new()

    found =
      indexed
      |> Enum.reverse()
      |> Enum.find_value(fn
        {{:board, b}, i} -> if k = by_board[b], do: {i, k}
        _other -> nil
      end)

    case found do
      {i, k} ->
        head = Enum.take(known, k)
        items = Enum.map(indexed, &elem(&1, 0))
        played = play(restored(tracker_opts, head, items, i), Enum.drop(items, i + 1))

        case compare(sans(played), sans(known)) do
          :extends -> {:extend, Enum.drop(played, length(known))}
          :conflict -> draft(:conflict, start_fen, played, known)
          _same_or_behind -> :nothing
        end

      nil ->
        case Enum.find(lines.(), &(&1 != [])) do
          nil -> {:unmatched, :no_anchor}
          line -> draft(:unknown_start, Chess.start_fen(), line, [])
        end
    end
  end

  # A tracker that has the game up to `known`, standing on reading `i`.
  defp restored(tracker_opts, known, items, i) do
    tracker = Tracker.restore(tracker_opts, Enum.map(known, &Map.take(&1, [:san, :flags])))
    {:board, board} = Enum.at(items, i)
    {tracker, _events} = Tracker.observe(tracker, 0, board)
    %{tracker: tracker, base: length(known), known: known}
  end

  defp last_index(indexed, fun) do
    indexed
    |> Enum.reverse()
    |> Enum.find_value(fn
      {{:board, b}, i} -> if fun.(b), do: i
      _other -> nil
    end)
  end

  # The board after each ply of the game, the start included; `nil` when
  # the game does not replay (it always should).
  defp boards(start_fen, sans) do
    with {:ok, start} <- Chess.parse_fen(start_fen),
         {:ok, played} <- Chess.replay(start_fen, sans) do
      [start.board | Enum.map(played, &start_board(&1.fen))]
    else
      _bad -> nil
    end
  end

  # --- playing readings through the tracker ------------------------------------

  # `[ply]`: the tracker's plies, the ones it found here marked `:memory`
  # and given the clock times the board wrote after them.
  defp play(%Tracker{} = tracker, items),
    do: play(%{tracker: tracker, base: 0, known: []}, items)

  defp play(%{tracker: tracker, base: base, known: known}, items) do
    {tracker, t, clocks, _last} =
      Enum.reduce(items, {tracker, 0, %{}, %{white: nil, black: nil}}, fn
        {:board, board}, {tr, t, clocks, last} ->
          t = t + @step_ms
          {tr, _events} = tr |> advance(t) |> Tracker.observe(t, board)
          {tr, t, clocks, last}

        {:clock, side, ms}, {tr, t, clocks, last} ->
          t = t + 10
          {tr, _events} = tr |> advance(t) |> Tracker.press(t)
          last = Map.put(last, side, ms)
          at = length(tr.plies) - 1

          clocks =
            if at >= base,
              do: Map.put(clocks, at, %{white_ms: last.white, black_ms: last.black}),
              else: clocks

          {tr, t, clocks, last}

        _start, acc ->
          acc
      end)

    tracker = advance(tracker, t + 60_000)

    tracker.plies
    |> Enum.with_index()
    |> Enum.map(fn {ply, i} ->
      case Enum.at(known, i) do
        %{san: san} = own when san == ply.san and i < base ->
          own

        _found_here ->
          %{
            san: ply.san,
            flags: Enum.uniq([:memory | ply.flags -- [:arbiter, :imported]]),
            clock: clocks[i]
          }
      end
    end)
  end

  # The tracker's own deadlines up to `t`, as the board process ticks it.
  defp advance(tracker, t) do
    case Tracker.deadline(tracker) do
      due when is_integer(due) and due <= t ->
        {next, _events} = Tracker.tick(tracker, due)
        if Tracker.deadline(next) == due, do: next, else: advance(next, t)

      _none ->
        tracker
    end
  end

  # --- comparing ---------------------------------------------------------------

  defp compare(line, known) do
    cond do
      line == known -> :same
      List.starts_with?(line, known) -> :extends
      List.starts_with?(known, line) -> :behind
      true -> :conflict
    end
  end

  defp draft(reason, start_fen, line, known) do
    from = common(sans(line), sans(known), 0)
    {:draft, reason, %{start_fen: start_fen, from_ply: from, plies: line}}
  end

  defp common([a | as], [a | bs], n), do: common(as, bs, n + 1)
  defp common(_as, _bs, n), do: n

  defp sans(plies), do: Enum.map(plies, & &1.san)

  defp tracker_opts(opts, start_fen),
    do: opts |> Map.new() |> Map.merge(%{start_fen: start_fen, late_start: false})

  defp start_board(fen) do
    case Chess.parse_fen(fen) do
      {:ok, pos} -> pos.board
      _bad -> nil
    end
  end

  defp turn(fen) do
    case Chess.parse_fen(fen) do
      {:ok, pos} -> pos.turn
      _bad -> nil
    end
  end
end
