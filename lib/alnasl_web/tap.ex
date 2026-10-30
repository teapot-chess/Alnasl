defmodule AlnaslWeb.Tap do
  @moduledoc """
  A move played on a drawn board: a tap on a piece, then a tap on where it
  goes. Typing `Nbd2` on a phone in a hall, with the players watching, is
  how `Nbf2` gets into a game.

  Pure: the state is what has been tapped so far, and each tap takes the
  position (a FEN) it is played in. Only legal moves come out the other
  end - the rules are `Alnasl.Chess`'s, the same that judge a typed move.

  The state:

      %{
        selected: square | nil,   # the piece picked up (0 = a8 .. 63 = h1)
        promo: square | nil,      # a pawn about to promote there: which piece?
        note: atom | nil          # why the last tap did nothing
      }

  Notes: `:empty` (nothing there to pick up), `:theirs` (the other side's
  piece, not its move), `:stuck` (that piece has no legal move), `:illegal`
  (the picked-up piece cannot go there), `:no_position`.
  """

  alias Alnasl.Chess

  @pieces %{"q" => :q, "r" => :r, "b" => :b, "n" => :n}

  @doc "Nothing picked up yet."
  def new, do: %{selected: nil, promo: nil, note: nil}

  @doc """
  A tap on `square` in the position `fen`:
  `{:move, san, state}` when a whole move has been made, `{:wait, state}`
  when not (a piece picked up, put down, a promotion to choose, or a tap
  that was refused - its note says why).
  """
  def tap(state, fen, square) when is_integer(square) and square in 0..63 do
    case position(fen) do
      nil ->
        {:wait, %{new() | note: :no_position}}

      pos ->
        legal = Chess.legal_moves(pos)
        piece = elem(pos.board, square)
        own? = match?({colour, _kind} when colour == pos.turn, piece)

        cond do
          state.selected == square ->
            {:wait, new()}

          own? and Enum.any?(legal, &(&1.from == square)) ->
            {:wait, %{new() | selected: square}}

          own? ->
            {:wait, %{new() | note: :stuck}}

          state.selected == nil ->
            {:wait, %{new() | note: if(piece == nil, do: :empty, else: :theirs)}}

          true ->
            case Enum.filter(legal, &(&1.from == state.selected and &1.to == square)) do
              [] -> {:wait, %{state | promo: nil, note: :illegal}}
              [move] -> {:move, Chess.san(pos, move), new()}
              _promotions -> {:wait, %{state | promo: square, note: nil}}
            end
        end
    end
  end

  def tap(state, _fen, _square), do: {:wait, state}

  @doc """
  The piece a waiting promotion becomes (`"q"`, `"r"`, `"b"` or `"n"`):
  `{:move, san, state}`, or `{:wait, state}` when there is no such promotion.
  """
  def promote(%{selected: from, promo: to} = state, fen, letter)
      when is_integer(from) and is_integer(to) do
    with %{} = pos <- position(fen),
         kind when kind != nil <- @pieces[letter],
         [move] <-
           Enum.filter(
             Chess.legal_moves(pos),
             &(&1.from == from and &1.to == to and &1.promo == kind)
           ) do
      {:move, Chess.san(pos, move), new()}
    else
      _no -> {:wait, state}
    end
  end

  def promote(state, _fen, _letter), do: {:wait, state}

  @doc """
  Where the picked-up piece may go, as `[{square, capture?}]`, for the dots.
  """
  def targets(%{selected: from}, fen) when is_integer(from) do
    case position(fen) do
      nil ->
        []

      pos ->
        for move <- Chess.legal_moves(pos), move.from == from, uniq: true do
          {move.to, move.capture != nil}
        end
    end
  end

  def targets(_state, _fen), do: []

  @doc "Whose move it is in `fen`: `:w`, `:b`, or nil."
  def turn(fen) do
    case position(fen) do
      nil -> nil
      pos -> pos.turn
    end
  end

  defp position(fen) when is_binary(fen) do
    case Chess.parse_fen(fen) do
      {:ok, pos} -> pos
      _error -> nil
    end
  end

  defp position(_none), do: nil
end
