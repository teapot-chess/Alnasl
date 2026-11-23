defmodule Alnasl.QuietClockTest do
  @moduledoc """
  A clock that stops reporting mid-game (Barco cup, 2026-11-23, round 3
  table 3): the moves the board still sees get no `[%clk]` made up for them,
  and the clock stands at the last time it really sent.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Clock, Position, Session, Tracker}

  defp boards(sans) do
    {:ok, played} = Chess.replay(Chess.start_fen(), sans)
    Enum.map(played, &Position.from_fen(&1.fen))
  end

  test "a move made while the clock is quiet has no clock; the clock stands still" do
    [e4, e5] = boards(~w(e4 e5))

    events = [
      {0, {:position, Position.start()}},
      {500, {:clock, %{white_ms: 180_000, black_ms: 180_000, running: :white}}},
      {3_000, {:position, e4}},
      {3_600, {:clock, %{white_ms: 177_000, black_ms: 180_000, running: :black}}},
      # Nothing from the clock after this; the board goes on.
      {60_000, {:position, e5}}
    ]

    {session, out} = Session.run(Session.new([]), events, tail_ms: 2_000)

    assert Tracker.sans(session.tracker) == ~w(e4 e5)
    stamps = for {_t, {:moves, plies}} <- out, ply <- plies, do: {ply.san, ply.clock}
    assert [{"e4", %{black_ms: 180_000}}, {"e5", nil}] = dedupe(stamps)

    assert Clock.read(session.clock, 600_000) ==
             %{white_ms: 177_000, black_ms: 180_000, running: :none, stale: true}
  end

  # The last stamp each move got.
  defp dedupe(stamps),
    do: stamps |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()
end
