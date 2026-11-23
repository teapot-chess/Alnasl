defmodule Alnasl.CaptureFixtures do
  @moduledoc """
  Capture files for tests (the format is `Arkab.Capture`'s): a game as the
  box would have recorded it, a reading a move, the clock pressed after
  each, the pieces set up from an empty board before it.
  """

  alias Alnasl.{Chess, Position}

  @step_ms 3_000

  @doc "A fresh directory to hold `board-<id>/` folders."
  def temp_root do
    root =
      Path.join(System.tmp_dir!(), "alnasl-captures-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root
  end

  @doc """
  A legal game of `n` plies, the same every time: quiet moves where there
  are any, no promotion, never one that leaves the other side without a move.
  """
  def game(n) do
    {:ok, start} = Chess.parse_fen(Chess.start_fen())

    {sans, _pos} =
      Enum.reduce(1..n//1, {[], start}, fn i, {acc, pos} ->
        moves = Chess.legal_moves(pos)
        playable = Enum.filter(moves, &(Chess.legal_moves(Chess.apply_move(pos, &1)) != []))
        quiet = Enum.filter(playable, &(&1.capture == nil and &1.promo == nil))
        pool = Enum.find([quiet, playable, moves], &(&1 != []))
        move = Enum.at(pool, rem(i * 37 + 11, length(pool)))
        {[Chess.san(pos, move) | acc], Chess.apply_move(pos, move)}
      end)

    Enum.reverse(sans)
  end

  @doc "The board after `sans`, from the start."
  def board_after([]), do: Position.start()

  def board_after(sans) do
    {:ok, played} = Chess.replay(Chess.start_fen(), sans)
    Position.from_fen(List.last(played).fen)
  end

  @doc """
  The capture lines of `sans` (maps, as written): a cfg line, the pieces
  set up, the starting position, then a reading and a clock press a ply.
  `:t0` is the wall-clock time of the first line (by default, far enough
  back that the whole game is over by now).
  """
  def lines(sans, opts \\ []) do
    t0 = opts[:t0] || System.os_time(:millisecond) - (length(sans) + 10) * @step_ms
    {:ok, played} = Chess.replay(Chess.start_fen(), sans)
    boards = Enum.map(played, &Position.from_fen(&1.fen))
    start = Position.start()
    half = Enum.reduce(32..63, start, &put_elem(&2, &1, nil))

    setup = [
      %{"t" => t0, "k" => "cfg", "flipped" => false, "driver" => "remote"},
      %{"t" => t0 + 100, "k" => "st", "v" => "connected"},
      %{"t" => t0 + 200, "k" => "pos", "b" => Position.to_text(Position.empty())},
      %{"t" => t0 + 1_000, "k" => "pos", "b" => Position.to_text(half)},
      %{"t" => t0 + 2_000, "k" => "pos", "b" => Position.to_text(start)}
    ]

    moves =
      boards
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {board, ply} ->
        t = t0 + 2_000 + ply * @step_ms
        running = if rem(ply, 2) == 1, do: "black", else: "white"

        [
          %{"t" => t, "k" => "pos", "b" => Position.to_text(board)},
          %{
            "t" => t + 600,
            "k" => "clk",
            "w" => 5_400_000 - ply * 1_000,
            "b" => 5_400_000 - ply * 1_000,
            "r" => running
          }
        ]
      end)

    setup ++ moves
  end

  @doc "Writes `lines` as board `board_id`'s capture file `name` under `root`."
  def write_lines(root, board_id, lines, name) do
    dir = Path.join(root, "board-#{board_id}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, Enum.map(lines, &[Jason.encode!(&1), ?\n]))
    path
  end

  @doc "Writes the capture of `sans` for board `board_id` (`:file`, `:t0`)."
  def write(root, board_id, sans, opts \\ []) do
    write_lines(root, board_id, lines(sans, opts), opts[:file] || "20261123-140000.jsonl")
  end
end
