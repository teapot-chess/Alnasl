defmodule Alnasl.BoardHistory.Capture do
  @moduledoc """
  The box's own memory of a board: its capture files (`Alnasl.Recorder`),
  read back when the game the box has for the board cannot be what stands
  on it. The other half of `Alnasl.BoardHistory`, which reads the board's
  memory: a LiveChess board has none to give (`:no_anchor`), and its
  capture has every reading the box ever had from it.

  ## How

  All the board's files, in time order. The last reading that showed the
  starting position is where the game began; from there the readings are
  played through a fresh session (`Alnasl.Session.run/3`, the one the live
  board and `Alnasl.Recorder.dry_run/3` use). The line it finds is taken
  only when it ends exactly on the board as it stands now. Anything less is
  a reason, not a game.

  ## What it is for

  2026-11-23, tournament 311: a select stepped through on the Boards page
  moved every game from table to table. A board relinked mid-game began a
  new game from the position in front of it (`game.from_board`) and the
  moves before it were gone; one game row was begun at a stale moment, one
  move from the position of ply 23, while the board was at ply 86, and
  stayed out of sync. Both games were in the captures, whole.

  The recovered line is trusted over the stored one: the stored row is the
  very thing that went wrong. Of the stored plies, those that are the same
  moves at the same place in the recovered line keep their times
  (`plies/2`); the rest are marked `imported`, with no time.
  """

  alias Alnasl.{Chess, Paths, Position, Session, Settings}

  # The newest files are read back to a starting position, and no further
  # than this much: a board that has not been set up for weeks has nothing
  # worth replaying.
  @max_bytes 64_000_000
  @tail_ms 5_500

  @type why :: :no_capture | :no_start | :no_moves | :does_not_reach

  @doc """
  The game on board `board_id` as its captures have it: `{:ok, sans}` from
  the standard starting position, or `{:error, why}`.

  Options: `:target` (required: the board as it stands, the way the box
  sees it), `:flipped?` (the board is turned round, for readings written
  before the capture says so), `:tracker` (the tracker's settings),
  `:root` (the captures directory).
  """
  @spec recover(term(), keyword()) :: {:ok, [String.t()]} | {:error, why()}
  def recover(board_id, opts) do
    target = Keyword.fetch!(opts, :target)
    root = opts[:root] || Paths.captures()

    with {:ok, lines} <- lines(Path.join(root, "board-#{board_id}")),
         {:ok, events} <- from_last_start(lines, opts[:flipped?] || false),
         {:ok, sans} <-
           replay(standing(events, target), opts[:tracker] || Settings.tracker_opts()) do
      if reaches?(sans, target), do: {:ok, sans}, else: {:error, :does_not_reach}
    end
  end

  @doc """
  The stored plies for a recovered line (`sans`, from the standard start),
  for a game that held `game_start` (its `start_fen`, `nil` for the
  standard one) and `stored` (its plies as `Alnasl.Games` keeps them,
  decoded JSON). Where the stored plies are the same moves at the same
  place in the recovered line, they are kept as they were, times and all;
  every other ply is `imported`, with no time.
  """
  def plies(sans, game_start, stored) do
    keep = kept(sans, game_start, stored)

    sans
    |> Enum.with_index()
    |> Enum.map(fn {san, i} ->
      Map.get(keep, i) || %{"san" => san, "flags" => ["imported"], "at" => nil, "clock" => nil}
    end)
  end

  # index in the recovered line => the stored ply that is that move.
  defp kept(_sans, _start, []), do: %{}

  defp kept(sans, game_start, stored) do
    stored_sans = Enum.map(stored, & &1["san"])
    n = length(stored_sans)

    with {:ok, start} <- Chess.parse_fen(game_start || Chess.start_fen()),
         {:ok, played} <- Chess.replay(Chess.start_fen(), sans) do
      fens = [Chess.start_fen() | Enum.map(played, & &1.fen)]
      sans = Enum.map(played, & &1.san)

      offset =
        fens
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn {fen, k} ->
          if same_position?(fen, start) and Enum.slice(sans, k, n) == stored_sans, do: k
        end)

      if offset,
        do: stored |> Enum.with_index(offset) |> Map.new(fn {ply, i} -> {i, ply} end),
        else: %{}
    else
      _no -> %{}
    end
  end

  defp same_position?(fen, start) do
    case Chess.parse_fen(fen) do
      {:ok, pos} -> pos.board == start.board and pos.turn == start.turn
      _bad -> false
    end
  end

  # --- reading -------------------------------------------------------------------

  # Every line of the board's newest files, oldest first, back to the newest
  # file with a starting position in it.
  # sobelow_skip ["Traversal.FileModule"]
  defp lines(dir) do
    names =
      case File.ls(dir) do
        {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".jsonl")) |> Enum.sort(:desc)
        _none -> []
      end

    if names == [] do
      {:error, :no_capture}
    else
      names
      |> Enum.reduce_while({[], 0}, fn name, {acc, bytes} ->
        text =
          case File.read(Path.join(dir, name)) do
            {:ok, text} -> text
            _gone -> ""
          end

        lines = parse(text)
        bytes = bytes + byte_size(text)
        acc = [lines | acc]

        if bytes >= @max_bytes or Enum.any?(lines, &start_line?/1),
          do: {:halt, {acc, bytes}},
          else: {:cont, {acc, bytes}}
      end)
      |> elem(0)
      |> List.flatten()
      |> Enum.sort_by(& &1["t"])
      |> then(&{:ok, &1})
    end
  end

  defp parse(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"t" => t, "k" => k} = fields} when is_integer(t) and k in ~w(pos clk cfg st) ->
          [fields]

        _other ->
          []
      end
    end)
  end

  @start_text Position.to_text(Position.start())
  @start_turned Position.to_text(Position.rotate(Position.start()))

  # Either way round: which way the board stood is the cfg lines' to say.
  defp start_line?(%{"k" => "pos", "b" => b}), do: b in [@start_text, @start_turned]
  defp start_line?(_line), do: false

  # The driver's events from the last starting position on, as the box saw
  # them (turned round where the board was), timed from that position.
  defp from_last_start(lines, flipped?) do
    {seen, _flipped} =
      Enum.map_reduce(lines, flipped?, fn
        %{"k" => "cfg"} = line, flipped ->
          {nil, Map.get(line, "flipped", flipped) == true}

        # A starting position the wrong way round is a board plugged in
        # turned round, as the box decides it (`BoardServer.orientation/1`).
        %{"k" => "pos", "b" => @start_turned} = line, _flipped ->
          {event(line, true), true}

        %{"k" => "pos", "b" => @start_text} = line, _flipped ->
          {event(line, false), false}

        line, flipped ->
          {event(line, flipped), flipped}
      end)

    timed = Enum.zip(lines, seen) |> Enum.reject(fn {_line, event} -> is_nil(event) end)

    start =
      timed
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {{_line, {:position, board}}, i} -> if board == Position.start(), do: i
        _other -> nil
      end)

    case start do
      nil ->
        {:error, :no_start}

      i ->
        [{%{"t" => t0}, _} | _] = rest = Enum.drop(timed, i)
        {:ok, Enum.map(rest, fn {%{"t" => t}, event} -> {t - t0, event} end)}
    end
  end

  defp event(%{"k" => "pos", "b" => text}, flipped?) do
    case Arkab.Board.from_text(text) do
      {:ok, board} -> {:position, if(flipped?, do: Position.rotate(board), else: board)}
      :error -> nil
    end
  end

  defp event(%{"k" => "clk", "r" => "off"}, _flipped?), do: {:info, %{clock: false}}

  defp event(%{"k" => "clk"} = line, _flipped?) do
    reading = %{white_ms: line["w"], black_ms: line["b"], running: running(line["r"])}

    case line["l"] do
      "white" -> {:clock, Map.put(reading, :armed, :white)}
      "black" -> {:clock, Map.put(reading, :armed, :black)}
      _none -> {:clock, reading}
    end
  end

  defp event(%{"k" => "st", "v" => "connected"}, _flipped?), do: :connected
  defp event(%{"k" => "st", "v" => "disconnected"}, _flipped?), do: :disconnected
  defp event(_line, _flipped?), do: nil

  defp running("white"), do: :white
  defp running("black"), do: :black
  defp running(_other), do: :none

  # --- replaying -----------------------------------------------------------------

  # The files are read as they are, without asking the recorder to close
  # them: a flush closes the board's file and the next reading begins a new
  # one, a file per recovery attempt. What the recorder still buffers (half
  # a second of it at most) is missing, so the board as the box sees it now
  # is the last reading - it is, after all, the last thing the board said.
  defp standing(events, target) do
    case List.last(Enum.filter(events, &match?({_t, {:position, _}}, &1))) do
      {_t, {:position, ^target}} -> events
      _other -> events ++ [{elem(List.last(events), 0) + 1_000, {:position, target}}]
    end
  end

  defp replay(events, tracker_opts) do
    opts =
      tracker_opts
      |> Keyword.put(:start_fen, Chess.start_fen())
      |> Keyword.put(:late_start, false)

    {session, _out} = Session.run(Session.new(opts), events, tail_ms: @tail_ms)

    case Enum.map(session.tracker.plies, & &1.san) do
      [] -> {:error, :no_moves}
      sans -> {:ok, sans}
    end
  end

  defp reaches?(sans, target) do
    case Chess.replay(Chess.start_fen(), sans) do
      {:ok, [_ | _] = played} -> Position.from_fen(List.last(played).fen) == target
      _no -> false
    end
  end
end
