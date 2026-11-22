defmodule Alnasl.ReversedClockTest do
  @moduledoc """
  A clock put down the other way round: its "white" half shows Black's
  time. The hall test of 2026-11-21 (round 10, eight boards) had this on
  several boards: times credited to the wrong player, White's clock going
  UP between its own moves, and moves that went missing.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Clock, Games, Position, Session, Tracker}

  # What a reversed clock says when White has `white` ms and Black `black`,
  # with `running` the side whose time REALLY runs.
  defp reversed(white, black, running) do
    side = %{white: :black, black: :white, none: :none}[running]
    {:clock, %{white_ms: black, black_ms: white, running: side}}
  end

  defp boards(sans) do
    {:ok, played} = Chess.replay(Chess.start_fen(), sans)
    Enum.map(played, &Position.from_fen(&1.fen))
  end

  # Each move: the piece goes down, stands, and the mover presses. White's
  # and Black's real times go down by 3 s a move; the increment is 2 s.
  defp game(sans, t0 \\ 1_000) do
    start = Position.start()

    events = [{0, {:position, start}}, {500, reversed(180_000, 180_000, :white)}]

    {events, _t, _w, _b} =
      sans
      |> boards()
      |> Enum.with_index()
      |> Enum.reduce({events, t0, 180_000, 180_000}, fn {board, i}, {acc, t, w, b} ->
        white? = rem(i, 2) == 0
        {w, b} = if white?, do: {w - 3_000 + 2_000, b}, else: {w, b - 3_000 + 2_000}
        next = if white?, do: :black, else: :white

        {acc ++ [{t, {:position, board}}, {t + 600, reversed(w, b, next)}], t + 3_000, w, b}
      end)

    events
  end

  test "started the other way round: every move is seen, every time belongs to its player" do
    sans = ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6)
    {session, out} = Session.run(Session.new([]), game(sans), tail_ms: 2_000)

    assert Tracker.sans(session.tracker) == sans
    assert session.swapped?
    assert session.clock_alarm == nil
    refute Enum.any?(out, &match?({_t, {:warning, _, _}}, &1))
    refute Enum.any?(out, &match?({_t, {:warning, _, _, _}}, &1))

    # The stamps. A move is stamped when it is accepted, with the mover's
    # time running; the other side's time stands still and is exact. Read
    # the wrong way round, White's "own" time went up between its moves.
    stamps =
      for {_t, {:moves, plies}} <- out, ply <- plies, ply.clock, do: ply.clock

    assert length(stamps) == length(sans)
    on_white = Enum.take_every(stamps, 2)
    on_black = stamps |> Enum.drop(1) |> Enum.take_every(2)
    assert Enum.map(on_white, & &1.black_ms) == [180_000, 179_000, 178_000, 177_000]
    assert Enum.map(on_black, & &1.white_ms) == [179_000, 178_000, 177_000, 176_000]
    whites = Enum.map(on_white, & &1.white_ms)
    assert whites == Enum.sort(whites, :desc)

    # And the clock as the site shows it: Black to move, Black's time running.
    assert Clock.read(session.clock, 0).running == :white
  end

  test "a clock found the other way round mid-game: turned from then on, the moves since restamped" do
    sans = ~w(e4 e5 Nf3 Nc6 Bb5 a6)
    [_e4, e5_board | _] = boards(sans)

    # A box restarted after 1. e4 e5 with the clock already running for
    # White on its "black" half: nothing was decided about it before.
    session = Session.restore([], ~w(e4 e5))
    {session, _} = Session.handle(session, 0, {:position, e5_board})
    {session, _} = Session.handle(session, 10, reversed(179_000, 179_000, :white))

    rest = sans |> boards() |> Enum.drop(2)

    {session, out} =
      rest
      |> Enum.with_index()
      |> Enum.reduce({session, []}, fn {board, i}, {session, out} ->
        t = 1_000 + i * 3_000
        {session, a} = Session.handle(session, t, {:position, board})
        {session, b} = Session.handle(session, t + 500, :tick)
        w = 179_000 - div(i + 2, 2) * 1_000
        bl = 179_000 - div(i + 1, 2) * 1_000
        next = if rem(i, 2) == 0, do: :black, else: :white
        {session, c} = Session.handle(session, t + 600, reversed(w, bl, next))
        {session, out ++ a ++ b ++ c}
      end)

    assert Tracker.sans(session.tracker) == sans
    assert session.swapped?
    # Decided on the second press that left the wrong side running; the
    # moves stamped before that, from ply 2 (Nf3) on, are swapped.
    assert {:clock_swapped, 2} in out
  end

  test "the stored game swaps the times of the moves from the ply it is told" do
    plies =
      Jason.encode!([
        %{"san" => "e4", "clock" => %{"white_ms" => 1, "black_ms" => 2}},
        %{"san" => "e5", "clock" => %{"white_ms" => 3, "black_ms" => 4}},
        %{"san" => "Nf3", "clock" => nil}
      ])

    swapped = Games.swap_clocks(Jason.decode!(plies), 1)

    assert Enum.at(swapped, 0)["clock"] == %{"white_ms" => 1, "black_ms" => 2}
    assert Enum.at(swapped, 1)["clock"] == %{"white_ms" => 4, "black_ms" => 3}
    assert Enum.at(swapped, 2)["clock"] == nil
  end

  test "the right way round stays the right way round" do
    sans = ~w(e4 e5 Nf3 Nc6)

    straight =
      Enum.map(game(sans), fn
        {t, {:clock, %{white_ms: w, black_ms: b, running: r}}} ->
          side = %{white: :black, black: :white, none: :none}[r]
          {t, {:clock, %{white_ms: b, black_ms: w, running: side}}}

        other ->
          other
      end)

    {session, out} = Session.run(Session.new([]), straight, tail_ms: 2_000)
    assert Tracker.sans(session.tracker) == sans
    refute session.swapped?
    refute Enum.any?(out, &match?({_t, {:clock_swapped, _}}, &1))
  end
end
