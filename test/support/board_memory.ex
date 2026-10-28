defmodule Alnasl.BoardMemory do
  @moduledoc """
  A board's memory written the way a DGT board writes one, for tests: the
  pieces lifted and put down for each move, and a clock time after it. The
  events are those of `{:history, events}` (Arkab's `Arkab.Dgt.Bus.history/1`).
  """

  alias Alnasl.Chess

  @doc "A whole memory: switched on, the starting position, `sans`."
  def game(sans), do: [:start_mark, :start_position | moves(sans)]

  @doc "What a board writes while `sans` are played from `fen`."
  def moves(sans, fen \\ Chess.start_fen(), clock_from \\ 5_400_000) do
    {:ok, pos} = Chess.parse_fen(fen)

    {events, _pos} =
      sans
      |> Enum.with_index()
      |> Enum.flat_map_reduce(pos, fn {san, i}, pos ->
        {:ok, m} = Chess.parse_san(pos, san)
        side = if pos.turn == :w, do: :white, else: :black
        hands = hands(pos, m)
        {hands ++ [{:clock, side, clock_from - 1_000 * (i + 1)}], Chess.apply_move(pos, m)}
      end)

    events
  end

  defp hands(pos, m) do
    us = pos.turn
    placed = if m.promo, do: {us, m.promo}, else: {us, m.piece}

    case m.kind do
      :castle_k ->
        [{:field, m.from, nil}, {:field, m.to, {us, :k}}] ++
          [{:field, m.to + 1, nil}, {:field, m.to - 1, {us, :r}}]

      :castle_q ->
        [{:field, m.from, nil}, {:field, m.to, {us, :k}}] ++
          [{:field, m.to - 2, nil}, {:field, m.to + 1, {us, :r}}]

      :ep ->
        taken = m.to + if(us == :w, do: 8, else: -8)
        [{:field, m.from, nil}, {:field, m.to, placed}, {:field, taken, nil}]

      _other ->
        taken = if elem(pos.board, m.to), do: [{:field, m.to, nil}], else: []
        taken ++ [{:field, m.from, nil}, {:field, m.to, placed}]
    end
  end

  @doc "The scan a board writes after a power-up: every piece of `fen`, square by square."
  def scan(fen) do
    {:ok, pos} = Chess.parse_fen(fen)
    for {piece, sq} <- Enum.with_index(Tuple.to_list(pos.board)), piece, do: {:field, sq, piece}
  end
end
