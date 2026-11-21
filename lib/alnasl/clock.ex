defmodule Alnasl.Clock do
  @moduledoc """
  What the chess clock on a board says: both times, which side runs, and how
  often it has been pressed.

  Pure, like the tracker. A reading is `%{white_ms, black_ms, running}` with
  `running` one of `:white | :black | :none`, and - from a driver that can
  tell - `armed`: the side whose time runs or, on a clock standing still,
  will run when it is started (`:white | :black`). A **press** is the running
  side changing from one player to the other; the count of presses is
  compared with the count of moves, because a press without a move is the
  earliest sign that the board missed one.

  ## Presses the running side hides

  Two presses between two readings leave the same side running, and a
  count of side changes misses both. The times do not: a side that is not
  running holds its time to the millisecond, so when the running side reads
  the same as before and the OTHER side's time has changed, that side ran
  in between - which takes a press to start and another to stop. Two are
  counted (`hidden_presses/2`). It is a floor: four look the same.

  The same goes for a side that comes back running with more time than it
  had when it stopped: only an increment pays a side for a press, so it
  pressed in between, and a single change of side was three presses.

  A clock that read standing still in between breaks the chain (the
  arbiter's time corrections are made with the clock stopped). An
  hourglass clock, on which the waiting side's time grows by what the
  running side's shrinks, is recognised the first time it does so, and
  from then on its times say nothing about presses. In 15,000 readings of
  the real board's clock (2026-10-11/12) the stopped side never moved.

  A board without a clock never sends a reading; `read/2` is then `nil` and
  nothing about clocks is reported. A clock that is switched off or
  unplugged (`off/2`) is a board without a clock again, until it reports.

  ## Sides

  White's side of the clock is fixed: the clock stands to the right of the
  board, White's display toward ranks 1-2 (the cable is too short for
  anything else, and DGT's own software assumes the same). So nothing here
  swaps sides or guesses colours. A clock that is turned round, or whose
  lever is the wrong way, is found by `start_check/2` before the game and
  raised as an alarm of its own if the game starts anyway.
  """

  defstruct white_ms: nil,
            black_ms: nil,
            running: :none,
            armed: nil,
            started: nil,
            at: nil,
            presses: 0,
            hourglass?: false,
            off?: false,
            # The side the clock itself last named as running, before
            # `by_the_times/3` had its say.
            flag: nil,
            # The last reading looked like a stale flag, or like two presses.
            suspect?: false

  @type t :: %__MODULE__{}
  @type reading :: %{white_ms: integer(), black_ms: integer(), running: atom()}
  @type side :: :white | :black

  # `started` is the side the clock was running on when it last went from
  # standing still (or from not being there) to running: `nil` while it
  # stands still. A press of the lever does not change it - which is how a
  # clock STARTED on Black's side is told from one that White pressed.

  def new, do: %__MODULE__{}

  @doc "Is a clock attached - has one reported, and not been switched off since?"
  def present?(%__MODULE__{at: at, off?: off?}), do: at != nil and not off?

  @doc "Takes a reading at time `t`. `{clock, pressed?}`."
  @spec update(t(), integer(), map()) :: {t(), boolean()}
  def update(%__MODULE__{} = clock, t, reading) do
    flag = Map.get(reading, :running, :none)
    {running, suspect?, undo} = by_the_times(clock, flag, reading)
    reading = Map.put(reading, :running, running)

    # A press is the clock's own flag changing sides. Where the times
    # overrule a flag that stayed put, nobody pressed anything.
    before = clock.flag || clock.running

    pressed? =
      before in [:white, :black] and flag in [:white, :black] and flag != before

    hourglass? = clock.hourglass? or hourglass?(clock, reading)
    hidden = if clock.off? or hourglass?, do: 0, else: hidden_presses(clock, reading)

    {%{
       clock
       | white_ms: Map.get(reading, :white_ms, clock.white_ms),
         black_ms: Map.get(reading, :black_ms, clock.black_ms),
         running: running,
         flag: flag,
         suspect?: suspect?,
         armed: Map.get(reading, :armed),
         started:
           cond do
             running == :none -> nil
             clock.running in [:white, :black] and not clock.off? -> clock.started
             true -> running
           end,
         at: t,
         off?: false,
         hourglass?: hourglass?,
         presses: clock.presses + hidden + if(pressed?, do: 1, else: 0) - undo
     }, pressed?}
  end

  # Which side runs, by the times when they and the flag disagree:
  # `{running, suspect?, presses_to_take_back}`.
  #
  # The flag is what the clock says about itself, and it can be stale: a
  # clock paused, its lever tipped over by hand and started again can go on
  # naming the side it named before, while the other side's time is the one
  # going down (seen in the hall 2026-11-21: Black named, Black's time
  # standing at 2:00:40, White's going down by a second a second). The time
  # that goes down is the time that runs.
  #
  # Once, that looks exactly like two presses between two readings ("Presses
  # the running side hides") and is counted so. Twice in a row under the
  # same flag it is not two more presses a second: it is the flag, the times
  # win from then on, and the two presses counted for it are taken back.
  #
  # Only between readings with the SAME flag, running both times: the
  # reading in which the flag changes is a press, and the side that just
  # pressed may well have lost a fraction of a second before it did. In the
  # same second neither time moves, and what was worked out before stands.
  defp by_the_times(%__MODULE__{hourglass?: true}, flag, _reading), do: {flag, false, 0}

  defp by_the_times(%__MODULE__{} = clock, flag, reading) when flag in [:white, :black] do
    other = other(flag)

    cond do
      clock.off? or clock.at == nil or clock.flag != flag or
          clock.running not in [:white, :black] ->
        {flag, false, 0}

      dropped?(clock, reading, other) and not dropped?(clock, reading, flag) ->
        cond do
          clock.running == other -> {other, false, 0}
          clock.suspect? -> {other, false, 2}
          true -> {flag, true, 0}
        end

      not dropped?(clock, reading, flag) and not dropped?(clock, reading, other) ->
        {clock.running, clock.suspect?, 0}

      true ->
        {flag, false, 0}
    end
  end

  defp by_the_times(_clock, flag, _reading), do: {flag, false, 0}

  defp dropped?(clock, reading, side) do
    key = if side == :white, do: :white_ms, else: :black_ms
    was = Map.get(clock, key)
    now = Map.get(reading, key)
    is_integer(was) and is_integer(now) and now < was
  end

  @doc """
  How many presses went by unseen between the clock as it stood and
  `reading`, as a floor: two when the same side runs in both and the other
  side's time has changed, two when the running side changed and the side
  now running has MORE time than when it last stood (it pressed in
  between, which only an increment repays), else none. See "Presses the
  running side hides".
  """
  @spec hidden_presses(t(), map()) :: 0 | 2
  def hidden_presses(%__MODULE__{running: side, hourglass?: false} = clock, reading)
      when side in [:white, :black] do
    now_running = Map.get(reading, :running)
    key = fn side -> if side == :white, do: :white_ms, else: :black_ms end
    changed = fn side -> {Map.get(clock, key.(side)), Map.get(reading, key.(side))} end

    case now_running do
      ^side ->
        case changed.(other(side)) do
          {was, now} when is_integer(was) and is_integer(now) and was != now -> 2
          _same -> 0
        end

      running when running in [:white, :black] ->
        case changed.(running) do
          {was, now} when is_integer(was) and is_integer(now) and now > was -> 2
          _less -> 0
        end

      _stopped ->
        0
    end
  end

  def hidden_presses(_clock, _reading), do: 0

  # The waiting side gained about what the running side lost: an hourglass,
  # on which a waiting side's time moving says nothing about presses.
  defp hourglass?(%__MODULE__{running: side} = clock, reading) when side in [:white, :black] do
    {mine, theirs} = if side == :white, do: {:white_ms, :black_ms}, else: {:black_ms, :white_ms}

    with ^side <- Map.get(reading, :running),
         was when is_integer(was) <- Map.get(clock, theirs),
         now when is_integer(now) and now > was <- Map.get(reading, theirs),
         lost when is_integer(lost) <- Map.get(clock, mine) do
      abs(now - was - (lost - Map.get(reading, mine, lost))) <= 1_000
    else
      _no -> false
    end
  end

  defp hourglass?(_clock, _reading), do: false

  defp other(:white), do: :black
  defp other(:black), do: :white

  @doc """
  The clock was switched off or unplugged at `t`. Nothing runs and nothing
  is read from it until it reports again; the presses counted so far stay.
  """
  @spec off(t(), integer()) :: t()
  def off(%__MODULE__{at: nil} = clock, _t), do: clock

  def off(%__MODULE__{} = clock, t) do
    now = read(clock, t)

    %{
      clock
      | white_ms: (now && now.white_ms) || clock.white_ms,
        black_ms: (now && now.black_ms) || clock.black_ms,
        running: :none,
        armed: nil,
        started: nil,
        at: t,
        hourglass?: false,
        off?: true
    }
  end

  @doc "The clock as it reads at `t`: the running side counted down since the last reading."
  @spec read(t(), integer()) :: reading() | nil
  def read(%__MODULE__{at: nil}, _t), do: nil
  def read(%__MODULE__{off?: true}, _t), do: nil

  def read(%__MODULE__{} = clock, t) do
    gone = max(t - clock.at, 0)

    %{
      white_ms: down(clock.white_ms, clock.running == :white, gone),
      black_ms: down(clock.black_ms, clock.running == :black, gone),
      running: clock.running
    }
  end

  defp down(nil, _running?, _gone), do: nil
  defp down(ms, true, gone), do: max(ms - gone, 0)
  defp down(ms, false, _gone), do: ms

  @doc """
  The side whose time runs, or will run when the clock is started: the
  running side, or on a clock standing still the side its lever is set for.
  `nil` without a clock, and for a clock standing still that does not say.
  """
  @spec first(t()) :: side() | nil
  def first(%__MODULE__{} = clock) do
    cond do
      not present?(clock) -> nil
      clock.running in [:white, :black] -> clock.running
      true -> clock.armed
    end
  end

  @doc """
  The clock's part of the starting-position check, for a game in which
  `to_move` (`:white`, or `:black` for a game from a set position) makes the
  first move:

  - `nil` - no clock attached: nothing to check;
  - `:ok` - the clock is set so that `to_move`'s time runs first: it stands
    still with the lever on that side, or it already runs on that side;
  - `{:wrong, side}` - the other side's time runs or would run first: the
    clock is turned round, or its lever is the wrong way.

  A clock standing still that does not say where its lever is (a simulated
  one) passes.
  """
  @spec start_check(t(), side()) :: nil | :ok | {:wrong, side()}
  def start_check(%__MODULE__{} = clock, to_move \\ :white) do
    cond do
      not present?(clock) -> nil
      first(clock) in [nil, to_move] -> :ok
      true -> {:wrong, first(clock)}
    end
  end

  @doc "`\"1:23:45\"` for a time in milliseconds."
  def format(nil), do: "-:--"

  def format(ms) do
    total = div(max(ms, 0), 1000)
    h = div(total, 3600)
    m = total |> rem(3600) |> div(60)
    s = rem(total, 60)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end
end
