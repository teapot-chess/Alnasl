defmodule Alnasl.ClockTest do
  @moduledoc """
  The press count, and the presses that only the times give away.
  """

  use ExUnit.Case, async: true

  alias Alnasl.Clock

  defp read(clock, readings) do
    Enum.reduce(readings, clock, fn {w, b, running}, clock ->
      {clock, _pressed?} = Clock.update(clock, 0, %{white_ms: w, black_ms: b, running: running})
      clock
    end)
  end

  test "a press is the running side changing" do
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {58_000, 60_000, :black}])
    assert clock.presses == 1
  end

  test "the same side running, and the other side's time moved: two presses went by unseen" do
    clock = read(Clock.new(), [{60_000, 60_000, :black}, {57_000, 59_000, :black}])
    assert clock.presses == 2

    assert Clock.hidden_presses(read(Clock.new(), [{1, 2, :white}]), %{
             white_ms: 0,
             black_ms: 1,
             running: :white
           }) == 2
  end

  test "the side now running has more time than when it stopped: it pressed in between" do
    # White pressed, Black moved and pressed (and got the increment), White
    # pressed again: one change of side, three presses.
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {85_000, 82_000, :black}])
    assert clock.presses == 3
  end

  test "the side now running with less time than it had is the one press it looks like" do
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {85_000, 59_000, :black}])
    assert clock.presses == 1
  end

  test "an hourglass is recognised once, and its times count for nothing after" do
    clock =
      read(Clock.new(), [
        {60_000, 60_000, :white},
        {57_000, 63_000, :white},
        {57_000, 63_000, :black},
        {60_000, 60_000, :white}
      ])

    assert clock.hourglass?
    assert clock.presses == 2
  end

  test "the running side's own time moving is no press" do
    clock =
      read(Clock.new(), [
        {60_000, 60_000, :white},
        {59_000, 60_000, :white},
        {58_000, 60_000, :white}
      ])

    assert clock.presses == 0
  end

  test "a time put right while the clock stood still is no press" do
    clock =
      read(Clock.new(), [
        {60_000, 60_000, :white},
        {59_000, 60_000, :none},
        {59_000, 180_000, :none},
        {59_000, 180_000, :white}
      ])

    assert clock.presses == 0
  end

  test "an hourglass: the waiting side gains what the running side loses, and that is no press" do
    # (And the first such reading is enough to know it.)
    clock = read(Clock.new(), [{60_000, 60_000, :white}, {57_000, 63_000, :white}])
    assert clock.presses == 0
  end

  test "a clock switched off and on again starts its chain afresh" do
    clock = read(Clock.new(), [{60_000, 60_000, :white}])
    clock = Clock.off(clock, 0)
    clock = read(clock, [{59_000, 50_000, :white}])
    assert clock.presses == 0
  end

  describe "a flag the times contradict (the hall, 2026-11-21, round 10 board 4)" do
    # Black named as running the whole time; Black's half standing at
    # 2:00:40, White's going down a second a second. The results site showed
    # Black's clock "running" and stuck, and White's counting down "stopped".
    @stale [
      {1_201_000, 7_240_000, :black},
      {1_200_000, 7_240_000, :black},
      {1_199_000, 7_240_000, :black},
      # the same second read twice
      {1_199_000, 7_240_000, :black},
      {1_198_000, 7_240_000, :black}
    ]

    test "the side whose time goes down is the side that runs, and no press is made of it" do
      clock = read(Clock.new(), @stale)

      assert clock.running == :white
      assert clock.presses == 0

      assert %{white_ms: 1_197_000, black_ms: 7_240_000, running: :white} =
               Clock.read(clock, 1_000)
    end

    test "once is two presses hidden between readings, as before; twice is the flag" do
      clock = read(Clock.new(), Enum.take(@stale, 2))
      assert clock.running == :black and clock.presses == 2

      clock = read(clock, [Enum.at(@stale, 2)])
      assert clock.running == :white and clock.presses == 0
    end

    test "a real press, the flag changing sides, is a press as ever" do
      clock = read(Clock.new(), @stale)
      # Somebody presses: the flag now names White, and Black's time goes.
      {clock, pressed?} =
        Clock.update(clock, 0, %{white_ms: 1_198_000, black_ms: 7_240_000, running: :white})

      assert pressed? and clock.presses == 1
      clock = read(clock, [{1_198_000, 7_239_000, :white}, {1_198_000, 7_238_000, :white}])
      assert clock.running == :black
    end

    test "a flag that agrees with the times is left alone" do
      clock = read(Clock.new(), [{60_000, 60_000, :white}, {59_000, 60_000, :white}])
      assert clock.running == :white and clock.presses == 0
    end
  end

  describe "a clock that goes quiet (Barco cup, 2026-11-23, round 3 table 3)" do
    setup do
      {clock, _} =
        Clock.update(Clock.new(), 1_000, %{white_ms: 382_000, black_ms: 611_000, running: :white})

      %{clock: clock}
    end

    test "is counted down while it might just be between two readings", %{clock: clock} do
      assert %{white_ms: 377_000, running: :white} = Clock.read(clock, 6_000)
      refute Clock.read(clock, 1_000 + Clock.stale_ms())[:stale]
    end

    test "past that it holds its last real reading, standing still, marked stale", %{clock: clock} do
      assert Clock.read(clock, 1_000 + 600_000) ==
               %{white_ms: 382_000, black_ms: 611_000, running: :none, stale: true}
    end

    test "the next reading is believed again", %{clock: clock} do
      {clock, _} =
        Clock.update(clock, 900_000, %{white_ms: 300_000, black_ms: 611_000, running: :white})

      assert %{white_ms: 299_000, running: :white} = Clock.read(clock, 901_000)
      refute Clock.read(clock, 901_000)[:stale]
    end

    test "a clock standing still is never stale" do
      {clock, _} =
        Clock.update(Clock.new(), 0, %{white_ms: 1_000, black_ms: 2_000, running: :none})

      assert Clock.read(clock, 3_600_000) == %{white_ms: 1_000, black_ms: 2_000, running: :none}
    end
  end
end
