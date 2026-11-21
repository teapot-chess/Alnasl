defmodule Alnasl.Session do
  @moduledoc """
  One game on one board: the tracker and the clock together.

  Still pure. It takes what a driver delivers - `{:position, board}`,
  `{:clock, reading}`, `{:info, %{clock: false}}` (the clock was switched
  off), `:connected`, `:disconnected` - and time passing, and returns the
  tracker's events with three additions:

  - every accepted ply carries the clock as it read when it was accepted
    (`ply.clock`, or `nil` without a clock);
  - `{:warning, :move_missing, presses, plies}` when the clock has been
    pressed at least twice more often than moves were seen, and
    `{:warning_cleared, :move_missing}` when the moves have caught up;
  - `{:clock_swapped, from_ply}` when the clock turns out to stand the
    other way round: the plies from `from_ply` (0-based) on carry their
    two times the wrong way and are to be swapped;
  - `{:warning, :clock_side, side}` / `{:warning_cleared, :clock_side}`:
    the clock alarm, below.

  ## Which half of the clock is White's

  Not fixed. The arbiter puts the clock where the cable reaches, and the
  box finds out which half is White's (see "which half is White's" in the
  code): before the first move the side that is started is the side to
  move, and during the game two presses in a row over a board in sync that
  leave the other side running mean the clock stands the other way round.
  From then on the readings are turned, and the moves already stamped the
  wrong way have their times swapped (`{:clock_swapped, from_ply}`).

  ## The clock alarm

  What is left of it: a clock that no longer agrees with itself in a way
  turning it round does not explain. It clears at the first press of the
  lever after which the running side is the side to move, or when the
  clock is switched off.

  The starting-position check (`clock_check/1`) only says whether a clock
  is there: which way it stands is no longer the arbiter's problem.

  `run/3` plays a whole list of timed events through it, ticking at the
  tracker's own deadlines: the test bench, and the dry run of a recording.
  """

  alias Alnasl.{Clock, Tracker}

  defstruct tracker: nil,
            clock: Clock.new(),
            missing?: false,
            clock_alarm: nil,
            # The clock stands the other way round: its "white" half is
            # Black's. Every reading is turned before anything reads it.
            swapped?: false,
            # The first ply stamped in the present orientation, and how many
            # presses in a row left the wrong side running (see "Which half
            # is White's").
            oriented_from: 0,
            mismatches: 0

  @type t :: %__MODULE__{}

  # Presses in a row, over a board in sync, that leave the side NOT to move
  # running before the box believes the clock is the other way round.
  @mismatch_limit 2

  def new(opts \\ []), do: %__MODULE__{tracker: Tracker.new(opts)}

  @doc """
  A session for a stored game. Which way the clock stands is not stored:
  it is found again, and only the moves from here on are restamped if it
  turns out to be the other way.
  """
  def restore(opts, plies) do
    tracker = Tracker.restore(opts, plies)
    %__MODULE__{tracker: tracker, oriented_from: length(tracker.plies)}
  end

  @spec handle(t(), integer(), term()) :: {t(), [tuple()]}
  def handle(%__MODULE__{} = session, t, {:position, board}) do
    session.tracker |> Tracker.observe(t, board) |> wrap(session, t)
  end

  def handle(%__MODULE__{} = session, t, {:clock, reading}) do
    {session, reading, reoriented?} = orient_at_start(session, reading)
    counted = session.clock.presses
    {clock, pressed?} = Clock.update(session.clock, t, reading)

    # The press that puts a wrongly started clock right before the first
    # move is somebody setting the clock, not a move: it is not counted
    # toward "a move is missing". Nor is one that only told the box which
    # half of the clock is White's.
    clock =
      if pressed? and
           (reoriented? or
              (session.clock_alarm != nil and session.tracker.plies == [] and
                 clock.running == to_move(session.tracker))),
         do: %{clock | presses: clock.presses - 1},
         else: clock

    # More presses than moves is how the reconstruction knows the board
    # has run further ahead than the shortest explanation says.
    # And more moves than presses, that it is making moves up.
    session = %{
      session
      | clock: clock,
        tracker:
          Tracker.presses(
            session.tracker,
            if(Clock.present?(clock), do: clock.presses),
            t
          )
    }

    # Presses the lever did not show but the times did (two between two
    # readings, `Clock.hidden_presses/2`) are presses all the same: the
    # board is looked at again as on any press.
    pressed? = pressed? or clock.presses > counted

    {session, events} =
      cond do
        not pressed? ->
          session |> check_missing([]) |> check_clock(false)

        # A press confirms the move that stands on the board only when it
        # is that move's press: the mover's clock stopped, the other side's
        # runs. A clock tells what happened up to a second late, and in
        # fast play the press of the move before arrives when the next
        # piece is already down - on a square where a rook may only be
        # resting on its way to castling.
        clock.running in [:none, to_move(session.tracker)] ->
          session.tracker |> Tracker.tick(t) |> wrap(session, t, true)

        true ->
          session.tracker |> Tracker.press(t) |> wrap(session, t, true)
      end

    {session, events} = if pressed?, do: watch_sides(session, events), else: {session, events}
    {session, [{:clock, Clock.read(session.clock, t)} | events]}
  end

  # The clock was switched off or unplugged: a board without a clock again.
  def handle(%__MODULE__{} = session, t, {:info, %{clock: false}}) do
    %{
      session
      | clock: Clock.off(session.clock, t),
        tracker: Tracker.presses(session.tracker, nil)
    }
    |> check_missing([])
    |> check_clock(false)
  end

  def handle(%__MODULE__{} = session, t, :tick) do
    session.tracker |> Tracker.tick(t) |> wrap(session, t)
  end

  # The cable was out: neither the pieces nor the clock were heard.
  def handle(%__MODULE__{} = session, _t, :disconnected),
    do: {%{session | tracker: Tracker.deaf(session.tracker)}, []}

  def handle(%__MODULE__{} = session, _t, _other), do: {session, []}

  @doc "Applies a tracker operation (`fn tracker -> {tracker, events} end`) made by the arbiter."
  def with_tracker(%__MODULE__{} = session, t, fun),
    do: session.tracker |> fun.() |> wrap(session, t)

  def deadline(%__MODULE__{tracker: tracker}), do: Tracker.deadline(tracker)

  @doc """
  The clock's part of the starting-position check: `nil` (no clock, or the
  game is under way) or `:ok`. Which way the clock stands is worked out
  when it is started, so a clock set the "wrong" way is not a problem.
  """
  def clock_check(%__MODULE__{tracker: %{plies: []}, clock: clock}),
    do: if(Clock.present?(clock), do: :ok)

  def clock_check(%__MODULE__{}), do: nil

  # --- which half is White's -----------------------------------------------------

  # A clock's halves are not White and Black: the arbiter puts it down where
  # the cable reaches, and half the hall then has White's time on the
  # "black" display. So the box works it out, from the two things that say:
  #
  # - before the first move, with the pieces in the starting position, the
  #   side that is started IS the side to move. Whatever runs then is
  #   White's half (in a game White begins), and the box turns its readings
  #   to match - again each time it is started otherwise before move one;
  # - during the game, a press over a board in sync leaves the side to move
  #   running. `@mismatch_limit` presses in a row that leave the other side
  #   running mean the clock stands the other way round: the readings are
  #   turned from then on, and the moves stamped since the last decision
  #   have their two times swapped (`{:clock_swapped, from_ply}`).
  #
  # A missed move cannot pass for this: it leaves the board out of sync,
  # and an out-of-sync press counts for nothing either way.

  defp orient_at_start(session, reading) do
    reading = turn(reading, session.swapped?)
    tracker = session.tracker
    running = Map.get(reading, :running, :none)

    if tracker.plies == [] and tracker.raw != nil and tracker.raw == tracker.pos.board and
         running in [:white, :black] and running != to_move(tracker) do
      session = %{
        session
        | swapped?: not session.swapped?,
          clock: swap_clock(session.clock),
          clock_alarm: nil,
          mismatches: 0,
          oriented_from: 0
      }

      {session, turn(reading, true), true}
    else
      {session, reading, false}
    end
  end

  defp watch_sides(session, events) do
    tracker = session.tracker
    running = session.clock.running

    cond do
      tracker.plies == [] or running not in [:white, :black] ->
        {session, events}

      tracker.status != :live or tracker.raw != tracker.phys ->
        {session, events}

      running == to_move(tracker) ->
        {%{session | mismatches: 0}, events}

      session.mismatches + 1 < @mismatch_limit ->
        {%{session | mismatches: session.mismatches + 1}, events}

      true ->
        from = session.oriented_from

        session = %{
          session
          | swapped?: not session.swapped?,
            clock: swap_clock(session.clock),
            clock_alarm: nil,
            mismatches: 0,
            oriented_from: length(tracker.plies)
        }

        {session, events ++ [{:clock_swapped, from}]}
    end
  end

  @doc "A clock reading with its halves swapped when `swap?`."
  def turn(reading, false), do: reading

  def turn(reading, true) when is_map(reading) do
    reading
    |> Map.merge(%{
      white_ms: Map.get(reading, :black_ms),
      black_ms: Map.get(reading, :white_ms),
      running: other_side(Map.get(reading, :running, :none))
    })
    |> then(fn turned ->
      if Map.has_key?(reading, :armed),
        do: Map.put(turned, :armed, other_side(reading.armed)),
        else: turned
    end)
  end

  defp swap_clock(%Clock{} = clock) do
    %{
      clock
      | white_ms: clock.black_ms,
        black_ms: clock.white_ms,
        running: other_side(clock.running),
        armed: other_side(clock.armed),
        started: other_side(clock.started)
    }
  end

  defp other_side(:white), do: :black
  defp other_side(:black), do: :white
  defp other_side(other), do: other

  defp to_move(%{pos: %{turn: :b}}), do: :black
  defp to_move(_tracker), do: :white

  defp wrap({tracker, events}, session, t, pressed? \\ false) do
    reading = Clock.read(session.clock, t)

    events =
      Enum.map(events, fn
        {:moves, plies} -> {:moves, stamp(plies, reading)}
        {:correction, keep, plies, reason} -> {:correction, keep, stamp(plies, reading), reason}
        other -> other
      end)

    %{session | tracker: tracker} |> check_missing(events) |> check_clock(pressed?)
  end

  defp stamp([], _reading), do: []

  defp stamp(plies, reading) do
    clock = reading && Map.take(reading, [:white_ms, :black_ms])
    {earlier, [last]} = Enum.split(plies, -1)
    Enum.map(earlier, &Map.put(&1, :clock, nil)) ++ [Map.put(last, :clock, clock)]
  end

  defp check_clock({session, events}, pressed?) do
    clock = session.clock
    to_move = to_move(session.tracker)
    started? = session.tracker.plies != []
    # The pieces stand as the game begins: before that, a clock running the
    # wrong way is one more thing not set up yet, not a game going wrong.
    at_start? = session.tracker.raw == session.tracker.pos.board

    alarm =
      cond do
        not Clock.present?(clock) -> nil
        not started? and Clock.start_check(clock, to_move) == :ok -> nil
        # Started there, not pressed over to there: a lever pressed to the
        # wrong side over untouched pieces is a first move the board did
        # not see, and "Move missing?" has that.
        not started? and at_start? and clock.started not in [nil, to_move] -> clock.running
        started? and pressed? and clock.running == to_move -> nil
        true -> session.clock_alarm
      end

    cond do
      alarm == session.clock_alarm ->
        {session, events}

      alarm == nil ->
        {%{session | clock_alarm: nil}, events ++ [{:warning_cleared, :clock_side}]}

      true ->
        {%{session | clock_alarm: alarm}, events ++ [{:warning, :clock_side, alarm}]}
    end
  end

  defp check_missing(session, events) do
    presses = session.clock.presses
    plies = length(session.tracker.plies)
    missing? = Clock.present?(session.clock) and presses >= plies + 2

    cond do
      missing? and not session.missing? ->
        {%{session | missing?: true}, events ++ [{:warning, :move_missing, presses, plies}]}

      session.missing? and not missing? ->
        {%{session | missing?: false}, events ++ [{:warning_cleared, :move_missing}]}

      true ->
        {session, events}
    end
  end

  @doc """
  Plays `timed` (`[{t, event}]`, in time order) through `session`, ticking at
  every deadline on the way and for `:tail_ms` (70 s) after the last event.
  Returns `{session, [{t, event}]}` with everything that came out.
  """
  @spec run(t(), [{integer(), term()}], keyword()) :: {t(), [{integer(), tuple()}]}
  def run(%__MODULE__{} = session, timed, opts \\ []) do
    tail = Keyword.get(opts, :tail_ms, 70_000)

    {session, out, last} =
      Enum.reduce(timed, {session, [], 0}, fn {t, event}, {session, out, _last} ->
        {session, out} = tick_until(session, t, out)
        {session, events} = handle(session, t, event)
        {session, prepend(out, t, events), t}
      end)

    {session, out} = tick_until(session, last + tail, out)
    {session, Enum.reverse(out)}
  end

  defp tick_until(session, t, out) do
    case deadline(session) do
      due when is_integer(due) and due < t ->
        {session, events} = handle(session, due, :tick)
        tick_until(session, t, prepend(out, due, events))

      _none ->
        {session, out}
    end
  end

  defp prepend(out, t, events), do: Enum.reduce(events, out, &[{t, &1} | &2])
end
