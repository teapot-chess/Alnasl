defmodule Alnasl.BoardServer do
  @moduledoc """
  One physical board, alive: its driver, what it reads, and - when it is
  linked to a game of the round - the tracker for that game.

  Everything a driver delivers passes through here, in this order:

  1. it is written to the capture file, exactly as delivered;
  2. the board is turned round if it is plugged in turned round (and that is
     noticed by itself: a start position that reads upside down);
  3. it is given to the game's session (`Alnasl.Session`: tracker and clock);
  4. what the session reports is applied: the game is saved to the database,
     the PGN rewritten, the update queued for the server (`Alnasl.Outbox`),
     the arbiter's log written;
  5. the site is told the board changed.

  Step 4 is one database write before one queue write: a move the site
  shows is a move that is saved, and a move that is saved is a move that is
  queued.

  ## Time

  The tracker is given time explicitly. For a real board that is the
  machine's monotonic clock. A simulated or replayed board brings its own
  time (`{:at, t, speed, next_t, event}`), possibly running twenty times too fast;
  the session then lives in that time, so the tracker's patience scales with
  the simulation. Between events the process ticks every 100 ms.

  ## The arbiter

  The repair tools of the site are calls on this process (`Alnasl.Boards`
  has the functions). Each is applied to the tracker, saved like any other
  change, sent to the server as a replacement of the game, and logged with
  who did it: the box has no accounts, so "the arbiter at the box".

  ## The board's memory

  A board that comes back - plugged in again, switched on again, or met for
  the first time - may have its own memory read by the driver and sent as
  `{:history, events}`. It is held up against the game (`Alnasl.BoardHistory`):
  moves that simply carry the game on are added, marked `:memory`, logged and
  sent like any others; anything else becomes a draft beside the game
  (`Alnasl.MemoryDrafts`) for the arbiter to accept or dismiss. The game is
  never overwritten by a memory on its own say-so.

  ## Waiting for the memory

  A board that has just been (re)connected through a driver that reads
  memories is about to hand over its memory. If the first readings show the
  game has run ahead, the moves in between are not guessed at once: the
  readings are held back (the session is left as it was) until the memory
  arrives, which then supplies the moves as they were played - no guess, no
  question for the arbiter. Only if the memory does not come within
  `:history_hold_ms` (25 s), or cannot be used, is the gap reconstructed the
  old way. Moves already guessed that the memory then agrees with lose
  their mark (`Alnasl.Games.confirm_guessed/2`).
  """

  use GenServer, restart: :transient

  alias Alnasl.{
    BoardLog,
    Chess,
    Clock,
    Driver,
    Games,
    LiveChessMatch,
    Log,
    MemoryDrafts,
    Outbox,
    Position,
    Recorder,
    Session,
    Settings,
    Tournaments,
    Tracker
  }

  alias Alnasl.Boards.Board

  @tick_ms 100
  # Polls missed in a row before the board counts as not heard.
  @deaf_after 3
  @topic "boards"

  def start_link(%Board{} = board) do
    GenServer.start_link(__MODULE__, board, name: via(board.id))
  end

  def via(id), do: {:via, Registry, {Alnasl.BoardRegistry, id}}

  def whereis(id) do
    case Registry.lookup(Alnasl.BoardRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc """
  Returns once everything sent to the board before this call has been
  dealt with - saved, queued, logged. A bridge's events are acknowledged
  only after this: "the server has it" has to mean the database has it.
  """
  def sync(pid), do: GenServer.call(pid, :sync, 30_000)

  # --- init --------------------------------------------------------------------

  @impl true
  def init(%Board{} = board) do
    Process.flag(:trap_exit, true)
    # The tracker's patience is changed in Setup while boards are playing.
    Settings.subscribe()

    state = %{
      board: board,
      driver: nil,
      raw: nil,
      seen: nil,
      connected?: false,
      last_seen: nil,
      stats: %{positions: 0, polls_ok: 0, polls_missed: 0},
      info: %{},
      # The clock as the board reports it, linked to a game or not: the
      # starting-position check wants it before there is a game.
      clock: Clock.new(),
      game: nil,
      session: nil,
      # What the board's memory offers the arbiter for this game, if
      # anything (`MemoryDrafts.summary/1`).
      draft: nil,
      # Waiting for the board's memory before a gap is guessed: the
      # monotonic time the wait ends (`nil`: not waiting), whether a gap
      # is actually being held back, and the clock reading that came with it.
      hold: nil,
      held?: false,
      held_clock: nil,
      time: {0, System.monotonic_time(:millisecond), 1.0, nil},
      last_t: 0,
      warning: nil,
      queued_at: nil,
      heartbeat_ms: (Settings.get("clock_heartbeat_s") || 20) * 1000,
      # The bytes the board sent last, for the debug log (`Alnasl.BoardLog`).
      last_rx: nil,
      # The board's memory as it last came, kept for a game that has not
      # begun on the box: the clock started over a game already under way
      # is caught up from it (see "A game the clock starts").
      memory: nil,
      # The time (the session's) the clock was started or pressed over a
      # game with no move yet.
      begin_at: nil,
      # "Play without a clock" for this board's tournament, and the round's
      # start time it waits for (`no_clock/1`); when the game started so.
      no_clock: %{on?: false, at: nil},
      started_without_clock: nil,
      # The captures were read for this game and this board, and gave
      # nothing (`from_capture/2`): `{game_id, board}`, so the same question
      # is not asked of the same files twice.
      capture_tried: nil,
      # Out of sync, and the captures already asked once this time.
      capture_episode?: false,
      # Who is playing, from a bridge's LiveChess board (`{:game, facts}`),
      # and what `Alnasl.LiveChessMatch` made of it: `%{facts, match}`.
      livechess: nil,
      dirty?: false
    }

    state = state |> load_game() |> start_driver()
    Process.send_after(self(), :tick, @tick_ms)
    Process.send_after(self(), :notify, 250)
    {:ok, state}
  end

  defp start_driver(%{board: board} = state) do
    opts = [
      owner: self(),
      id: board.id,
      port: board.port,
      address: board.address,
      options: Board.options(board)
    ]

    case Driver.module(board.driver).start_link(opts) do
      {:ok, pid} ->
        dbg(state, :connection, "driver.started", %{
          driver: board.driver,
          port: board.port,
          address: board.address
        })

        %{state | driver: pid}

      {:error, reason} ->
        Log.add(:error, "board.driver_failed", %{reason: inspect(reason)}, ref(state))
        Process.send_after(self(), :restart_driver, 3_000)
        %{state | driver: nil}
    end
  rescue
    error ->
      Log.add(:error, "board.driver_failed", %{reason: Exception.message(error)}, ref(state))
      Process.send_after(self(), :restart_driver, 3_000)
      %{state | driver: nil}
  end

  # The game this board is linked to, and a session caught up with it.
  defp load_game(%{board: %Board{tournament_id: tournament, round: round, board_no: no}} = state)
       when is_integer(round) and is_integer(no) do
    pairing = Tournaments.board(tournament, round, no)
    game = Games.ensure(tournament, round, no, Games.pairing_attrs(pairing))
    # The results site lists the board from now, not from its first move.
    if pairing, do: Outbox.announce(game)

    opts =
      Settings.tracker_opts()
      |> Keyword.put(:start_fen, game.start_fen)
      # A second game on a board began on a board that showed the first.
      |> Keyword.put(:late_start, game.game_no == 1)

    plies = Games.plies(game)
    session = Session.restore(opts, plies)
    Recorder.record(state.board.id, {:cfg, cfg(state.board, game)})

    dbg(
      state,
      :other,
      "game.linked",
      %{round: round, board: no, game: game.game_no, plies: length(plies), status: game.status},
      "start FEN " <> (game.start_fen || Chess.start_fen())
    )

    with_draft(%{
      state
      | game: game,
        session: session,
        warning: nil,
        begin_at: nil,
        started_without_clock: nil,
        no_clock: no_clock(state.board),
        capture_episode?: false
    })
  end

  defp load_game(state) do
    Recorder.record(state.board.id, {:cfg, cfg(state.board, nil)})
    dbg(state, :other, "game.unlinked")

    %{
      state
      | game: nil,
        session: nil,
        warning: nil,
        draft: nil,
        begin_at: nil,
        started_without_clock: nil,
        no_clock: %{on?: false, at: nil}
    }
  end

  # "Play without a clock" (`Alnasl.Tournaments.no_clock?/1`) and when the
  # round starts, as OpenPairings has it (`Alnasl.Tournaments.round_start/2`).
  defp no_clock(%Board{tournament_id: tid, round: round}) when is_integer(tid) do
    if Tournaments.no_clock?(tid),
      do: %{
        on?: true,
        at: Tournaments.round_start(tid, round),
        asked: System.monotonic_time(:millisecond)
      },
      else: %{on?: false, at: nil}
  end

  defp no_clock(_board), do: %{on?: false, at: nil}

  # The draft waiting on this game, read again after anything that may
  # have changed it.
  defp with_draft(%{game: %{id: id}} = state),
    do: %{state | draft: MemoryDrafts.summary(MemoryDrafts.pending(id))}

  defp with_draft(state), do: %{state | draft: nil}

  defp cfg(board, game) do
    %{
      driver: board.driver,
      port: board.port,
      address: board.address,
      flipped: board.flipped,
      round: board.round,
      board: board.board_no,
      game: game && game.game_no,
      start_fen: game && game.start_fen
    }
  end

  # --- from the driver ---------------------------------------------------------

  @impl true
  def handle_info({:driver, _id, {:at, t, speed, next, event}}, state) do
    state = %{state | time: {t, System.monotonic_time(:millisecond), speed, next}}
    {:noreply, driver_event(state, event, t)}
  end

  def handle_info({:driver, _id, event}, state),
    do: {:noreply, driver_event(state, event, now(state))}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    t = now(state)

    {:noreply,
     state
     |> expire_hold()
     |> advance(t)
     |> start_without_clock(t)
     |> begin_from_board(t)
     |> heartbeat(t)}
  end

  # Tells the site, at most four times a second.
  def handle_info(:notify, state) do
    Process.send_after(self(), :notify, 250)

    if state.dirty? do
      Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:board, state.board.id})
      {:noreply, %{state | dirty?: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:restart_driver, %{driver: nil} = state) do
    dbg(state, :connection, "driver.restart")
    {:noreply, start_driver(state)}
  end

  def handle_info(:restart_driver, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{driver: pid} = state) do
    if reason not in [:normal, :shutdown] do
      Log.add(:error, "board.driver_failed", %{reason: inspect(reason, limit: 5)}, ref(state))
    end

    Process.send_after(self(), :restart_driver, 3_000)
    {:noreply, dirty(%{state | driver: nil, connected?: false})}
  end

  # Setup changed the tracker's settings ("Bullet / fast play", or a number
  # by hand): the game under way goes on with them, from its next reading.
  def handle_info({:setting, "tracker"}, %{session: %{tracker: tracker} = session} = state) do
    opts =
      Tracker.defaults()
      |> Map.merge(Map.new(Settings.tracker_opts()))
      |> Map.put(:late_start, tracker.opts.late_start)

    {:noreply, %{state | session: %{session | tracker: %{tracker | opts: opts}}}}
  end

  # "Play without a clock" switched for this board's tournament.
  def handle_info({:setting, "no_clock:" <> _tid}, state),
    do: {:noreply, dirty(%{state | no_clock: no_clock(state.board)})}

  def handle_info(_other, state), do: {:noreply, state}

  defp driver_event(state, {:position, board}, t) do
    Recorder.record(state.board.id, {:position, board})
    # Somebody touched it: "which board is this?" (`Alnasl.Finder`).
    Alnasl.Finder.reading(state.board.id, state.raw, board)

    state = %{
      state
      | raw: board,
        last_seen: DateTime.utc_now(:second),
        stats: Map.update!(state.stats, :positions, &(&1 + 1))
    }

    before = state.seen
    state = orientation(state)
    seen = if state.board.flipped, do: Position.rotate(board), else: board
    state = %{state | seen: seen}
    log_position(state, before, seen)
    state |> feed(t, {:position, seen}) |> dirty()
  end

  defp driver_event(state, {:clock, reading}, t) do
    Recorder.record(state.board.id, {:clock, reading})
    before = state.clock
    {clock, pressed?} = Clock.update(state.clock, t, reading)
    log_clock(state, before, reading, pressed?)
    started? = clock.running != :none and state.clock.running == :none
    state = %{state | clock: clock, info: Map.put(state.info, :clock, true)}
    state |> feed(t, {:clock, reading}) |> note_begin(t, started? or pressed?) |> dirty()
  end

  # The clock was switched off or unplugged: no clock, so no clock check and
  # no clock alarm, until it reports again.
  defp driver_event(state, {:info, %{clock: false} = info}, t) do
    Recorder.record(state.board.id, {:clock, :off})
    if Clock.present?(state.clock), do: dbg(state, :clock, "clock.off")
    state = %{state | clock: Clock.off(state.clock, t), info: Map.merge(state.info, info)}
    state |> feed(t, {:info, %{clock: false}}) |> dirty()
  end

  defp driver_event(state, :connected, _t) do
    Recorder.record(state.board.id, {:status, :connected})
    unless state.connected?, do: Log.add(:info, "board.connected", %{}, ref(state))
    state = if state.connected?, do: state, else: wait_for_memory(state)
    dirty(%{state | connected?: true, last_seen: DateTime.utc_now(:second)})
  end

  defp driver_event(state, :disconnected, _t) do
    Recorder.record(state.board.id, {:status, :disconnected})
    if state.connected?, do: Log.add(:warn, "board.disconnected", %{}, ref(state))

    # It may be on another port already: replugged faster than this one
    # noticed the cable was out (`Alnasl.Tables.settle/1`).
    if state.connected?, do: Alnasl.Finder.gone(state.board)

    # Its clock is not heard either while it is gone (`Tracker.deaf/1`).
    session =
      state.session && %{state.session | tracker: Tracker.deaf(state.session.tracker)}

    dirty(%{state | connected?: false, session: session})
  end

  defp driver_event(state, {:info, info}, _t) do
    told = Map.take(info, [:serial, :firmware, :bus_address, :loop])

    if told != %{} and told != Map.take(state.info, Map.keys(told)),
      do: dbg(state, :connection, "board.info", told, inspect(info, limit: 20))

    state = %{state | info: Map.merge(state.info, info)}
    loop_by_itself(state, info)

    # A board alone on its port says which number it answers to on a loop:
    # kept with the row, so that it is known again when it is on one.
    # (A bridge's board keeps its number in its port; nothing to keep here.)
    alone = if state.board.driver == "dgt_serial", do: info[:bus_address]

    changes =
      %{serial: info[:serial], firmware: info[:firmware], address: alone}
      |> Map.reject(fn {key, value} -> value == nil or Map.get(state.board, key) == value end)
      # A row that has a serial is that board; another serial on its port
      # is another board, not a new name for this one.
      |> Alnasl.Tables.keep_identity(state.board)

    state =
      if changes == %{} do
        state
      else
        %{state | board: state.board |> Board.changeset(changes) |> Alnasl.Repo.update!()}
      end

    # A board that says who it is may be one the box already knows, on
    # another port - or not the board this row is (`Alnasl.Tables.recognise/4`).
    if info[:serial], do: Alnasl.Finder.identified(state.board, info[:serial])

    dirty(state)
  end

  defp driver_event(state, {:poll, :ok}, t), do: driver_event(state, {:poll, :ok, 1}, t)

  # A bridge sends one "answered" a second for a loop board that answers
  # sixty times a second, and says how many it stands for. An older bridge
  # says nothing and counts as one.
  defp driver_event(state, {:poll, :ok, n}, _t) when is_integer(n) and n > 0,
    do: %{
      state
      | stats: state.stats |> Map.update!(:polls_ok, &(&1 + n)) |> Map.put(:missed_run, 0),
        last_seen: DateTime.utc_now(:second)
    }

  # A board on a loop that misses a poll now and then is a noisy line.
  # One that misses several in a row was not heard for that long, and its
  # clock with it: a hole in what the box knows (`Tracker.deaf/1`), which is
  # the one thing that lets the reconstruction consider moves it has no
  # reading for.
  defp driver_event(state, {:poll, :missed}, _t) do
    run = Map.get(state.stats, :missed_run, 0) + 1

    session =
      if run == @deaf_after and state.session,
        do: %{state.session | tracker: Tracker.deaf(state.session.tracker)},
        else: state.session

    stats = state.stats |> Map.update!(:polls_missed, &(&1 + 1)) |> Map.put(:missed_run, run)
    if run == @deaf_after, do: dbg(state, :connection, "poll.deaf", %{run: run}, nil, :warn)
    dirty(%{state | stats: stats, session: session})
  end

  # Kept, not logged line by line: a loop answers sixty times a second. The
  # last bytes the board sent go with the next reading in the debug log.
  defp driver_event(state, {:raw, direction, bytes}, _t) do
    Recorder.record(state.board.id, {:raw, direction, bytes})
    if direction == :rx and is_binary(bytes), do: %{state | last_rx: bytes}, else: state
  end

  # The board's own memory. Whatever is wrong with it, this process goes on
  # and the game stays as it was.
  defp driver_event(state, {:history, events}, _t) when is_list(events) do
    dbg(state, :connection, "history.received", %{count: length(events)})
    %{state | memory: events} |> recover(events) |> release() |> livechess_result()
  rescue
    error ->
      Log.add(:error, "board.history_failed", %{reason: Exception.message(error)}, ref(state))
      release(state)
  end

  # Who is playing, from a LiveChess board: the pairing is looked up beside
  # this process when the players change, and a result in the file is
  # suggested, as a board suggests one.
  defp driver_event(state, {:game, facts}, _t) when is_map(facts) do
    before = state.livechess
    changed? = before == nil or LiveChessMatch.key(before.facts) != LiveChessMatch.key(facts)
    state = %{state | livechess: %{facts: facts, match: before && before.match}}

    if changed? do
      dbg(state, :other, "livechess.game", Map.take(facts, [:round, :game]))
      LiveChessMatch.kick(state.board.id)
    end

    if facts[:forfeit] && (before == nil or before.facts[:forfeit] != facts[:forfeit]),
      do: Log.add(:warn, "livechess.forfeit", %{side: facts.forfeit}, ref(state))

    state |> livechess_result() |> dirty()
  end

  defp driver_event(state, _other, _t), do: state

  @decided ["1-0", "0-1", "1/2-1/2"]

  # LiveChess's result, for the arbiter to confirm: the path a board's
  # own suggestion takes.
  defp livechess_result(
         %{livechess: %{facts: %{result: result}}, session: session, game: game} = state
       )
       when result in @decided and session != nil and game != nil do
    if game.status == "finished", do: state, else: suggest(state, result, :livechess)
  end

  defp livechess_result(state), do: state

  # A LiveChess board put on its pairing after its game arrived: the game
  # came as its memory, and is played into the pairing's game now, move by
  # move, instead of being guessed from the last position.
  defp catch_up(%{livechess: %{}, memory: [_ | _] = memory} = state),
    do: state |> recover(memory) |> livechess_result()

  defp catch_up(state), do: state

  # A memory is for the game under way; a finished game has its moves, and
  # a board with no game has nothing to hold it up against.
  defp recover(%{session: nil} = state, _events), do: state
  defp recover(%{game: %{status: "finished"}} = state, _events), do: state

  defp recover(state, events) do
    game = state.game

    known = Games.plies(game)

    {result, agreed} =
      Alnasl.BoardHistory.merge_detail(events,
        start_fen: game.start_fen,
        plies: known,
        flipped?: state.board.flipped,
        tracker: Settings.tracker_opts()
      )

    case result do
      {:extend, plies} ->
        {game, confirmed} = Games.confirm_guessed(game, agreed)
        log_confirmed(state, confirmed)
        {game, _} = Games.apply_event(game, {:moves, plies}, System.os_time(:millisecond))
        sans = Enum.map(plies, & &1.san)
        Log.add(:warn, "board.history_merged", %{moves: sans, count: length(sans)}, ref(state))

        state
        |> resume(game)
        |> enqueue(now(state), false)
        |> refeed()
        |> dirty()

      {:draft, reason, draft} ->
        case MemoryDrafts.offer(game.id, state.board.serial, reason, draft) do
          {:new, _draft} ->
            Log.add(
              :warn,
              "board.history_draft",
              %{reason: to_string(reason), count: length(draft.plies) - draft.from_ply},
              ref(state)
            )

            state |> with_draft() |> dirty()

          {:known, _draft} ->
            state
        end

      :nothing ->
        {game, confirmed} = Games.confirm_guessed(game, agreed)

        if confirmed > 0 do
          log_confirmed(state, confirmed)

          state
          |> resume(game)
          |> enqueue(now(state), true)
          |> refeed()
          |> dirty()
        else
          Log.add(:info, "board.history_matches", %{}, ref(state))
          state
        end

      {:unmatched, reason} ->
        Log.add(:info, "board.history_unmatched", %{reason: to_string(reason)}, ref(state))
        # A board that remembers nothing the game knows (a LiveChess board
        # gives no memory worth the name): the box's own recording of it.
        if reason == :no_anchor, do: elem(from_capture(state, :memory), 1), else: state
    end
  end

  defp log_confirmed(_state, 0), do: :ok

  defp log_confirmed(state, count),
    do: Log.add(:info, "board.history_confirmed", %{count: count}, ref(state))

  # --- the box's own recording of the board ------------------------------------

  # How far the tracker's late start reaches by itself (`Tracker`, `paths/5`).
  @late_start_plies 2

  # The board stands somewhere the game the box has for it never was: the
  # box reads its own captures of the board back from the last starting
  # position (`Alnasl.BoardHistory.Capture`) and, when that line ends on
  # the board as it stands, the game becomes it, sent whole. `why` says what
  # asked: `:linked` (linked mid-game to a game with no moves),
  # `:clock_started` (instead of beginning from the board), `:out_of_sync`
  # (stuck), `:memory` (the board's own memory knew nothing). Returns
  # `{:ok | :error, state}`; asked once per game and board position.
  defp from_capture(state, why) do
    key = state.game && {state.game.id, state.seen}

    if capture_wanted?(state) and state.capture_tried != key do
      read_capture(%{state | capture_tried: key}, why)
    else
      {:error, state}
    end
  end

  defp capture_wanted?(%{session: %{tracker: tracker}, game: game, seen: seen})
       when seen != nil,
       do: game.status != "finished" and tracker.pos.board != seen

  defp capture_wanted?(_state), do: false

  defp read_capture(state, why) do
    result =
      Alnasl.BoardHistory.Capture.recover(state.board.id,
        target: state.seen,
        flipped?: state.board.flipped,
        tracker: Settings.tracker_opts()
      )

    case result do
      # A board plugged in a move or two into its game is the tracker's own
      # late start, which catches it up and marks it so.
      {:ok, sans} when why == :linked and length(sans) <= @late_start_plies ->
        if state.session.tracker.opts.late_start,
          do: {:error, %{state | capture_tried: nil}},
          else: take_capture(state, sans, why)

      {:ok, sans} ->
        take_capture(state, sans, why)

      {:error, reason} ->
        Log.add(
          :info,
          "board.history_recovery_failed",
          %{reason: to_string(reason), why: to_string(why)},
          ref(state)
        )

        {:error, state}
    end
  rescue
    error ->
      Log.add(
        :error,
        "board.history_recovery_failed",
        %{reason: Exception.message(error), why: to_string(why)},
        ref(state)
      )

      {:error, state}
  end

  defp take_capture(state, sans, why) do
    stored = Jason.decode!(state.game.plies)
    plies = Alnasl.BoardHistory.Capture.plies(sans, state.game.start_fen, stored)
    game = Games.recover_line(state.game, plies)

    Log.add(
      :warn,
      "board.history_recovered",
      %{count: length(sans), why: to_string(why)},
      ref(state)
    )

    state = %{state | capture_tried: nil}
    {:ok, state |> resume(game) |> enqueue(now(state), true) |> refeed() |> dirty()}
  end

  # Linked to a game with no moves while the board is in the middle of one:
  # the captures, before anything begins from the pieces as they stand.
  defp linked_mid_game(%{session: %{tracker: %{plies: []} = tracker}, seen: seen} = state)
       when seen != nil do
    if seen != start_board(tracker), do: elem(from_capture(state, :linked), 1), else: state
  end

  defp linked_mid_game(state), do: state

  # Out of sync with nothing to show for it: the captures, once a time.
  defp stuck(state, events) do
    stuck? =
      Enum.any?(events, fn
        {:status, :out_of_sync, why} -> why in [:unexplained, :search_gave_up]
        _other -> false
      end)

    back? =
      Enum.any?(events, &match?({:status, status, _} when status in [:live, :waiting_start], &1))

    cond do
      back? ->
        %{state | capture_episode?: false}

      stuck? and not state.capture_episode? ->
        elem(from_capture(%{state | capture_episode?: true}, :out_of_sync), 1)

      true ->
        state
    end
  end

  # --- a game the clock starts ---------------------------------------------------

  # The clock is started (or pressed) over a game without a move, on a board
  # that does not show the game's starting position: the game starts from
  # what is on the board. Not at once: the tracker is given
  # `@begin_after_ms` to see a first move it understands, and the pieces
  # must have stood still for `@begin_stable_ms`. Then, in this order:
  #
  # 1. the board's memory, when it has one: a game that was already under
  #    way is caught up from it, moves as they were played;
  # 2. otherwise the game starts over from the position on the board, with
  #    the side whose clock runs to move (`Position.fen/2`: castling where
  #    king and rook stand at home, no en passant).
  #
  # Once per start of the clock. A board that cannot be read as a position
  # (no king, two kings) is left as it was, for the arbiter.
  @begin_after_ms 2_000
  @begin_stable_ms 1_000

  defp note_begin(%{session: %{tracker: %{plies: []}}, game: %{status: status}} = state, t, true)
       when status != "finished" do
    if state.session.clock.running in [:white, :black] and state.begin_at == nil,
      do: %{state | begin_at: t},
      else: state
  end

  defp note_begin(state, _t, _started?), do: state

  defp begin_from_board(%{begin_at: nil} = state, _t), do: state

  defp begin_from_board(state, t) do
    cond do
      not beginnable?(state) ->
        %{state | begin_at: nil}

      t - state.begin_at < @begin_after_ms or state.hold != nil or
          t - state.session.tracker.raw_since < @begin_stable_ms ->
        state

      true ->
        turn =
          case state.session.clock.running do
            :black -> :b
            :white -> :w
            _none -> state.session.tracker.pos.turn
          end

        begin_here(%{state | begin_at: nil}, t, turn)
    end
  end

  # A game that has not begun, on a board that shows something else than
  # its starting position.
  defp beginnable?(%{session: %{tracker: tracker}, game: %{status: status}, seen: seen})
       when seen != nil and status != "finished" do
    tracker.plies == [] and tracker.status != :live and seen != start_board(tracker)
  end

  defp beginnable?(_state), do: false

  defp begin_here(state, t, turn) do
    state = if memory_fits?(state), do: recover(state, state.memory), else: state

    # Then the box's own recording of the board, which has the game from
    # its starting position when the box was listening all along. Only
    # failing that does the game begin where the pieces stand.
    state =
      if state.session.tracker.plies == [],
        do: elem(from_capture(state, :clock_started), 1),
        else: state

    if state.session.tracker.plies != [] do
      Log.add(:info, "game.caught_up", %{count: length(state.session.tracker.plies)}, ref(state))
      state
    else
      fen = Position.fen(state.seen, turn)

      case Tracker.set_position(state.session.tracker, t, fen) do
        {:ok, result} ->
          {:ok, state} =
            tracked(state, t, fn _tr -> result end, "game.from_board", %{fen: fen}, "box")

          dirty(state)

        {:error, _message} ->
          state
      end
    end
  end

  # The memory carries this game on to exactly the board as it stands: a
  # line from an older game with the same opening does not.
  defp memory_fits?(%{memory: memory, game: game} = state) when is_list(memory) do
    known = Games.plies(game)

    result =
      Alnasl.BoardHistory.merge(memory,
        start_fen: game.start_fen,
        plies: known,
        flipped?: state.board.flipped,
        tracker: Settings.tracker_opts()
      )

    with {:extend, plies} <- result,
         sans = Enum.map(known ++ plies, & &1.san),
         {:ok, [_ | _] = played} <- Chess.replay(game.start_fen || Chess.start_fen(), sans) do
      Position.from_fen(List.last(played).fen) == state.seen
    else
      _no -> false
    end
  end

  defp memory_fits?(_state), do: false

  # "Play without a clock", on a board that has none: at the round's start
  # time (at once, when OpenPairings gives none) the game counts as begun -
  # and a board set up with something else than the starting position
  # starts from it, as the clock would have started it.
  defp start_without_clock(
         %{no_clock: %{on?: true}, started_without_clock: nil} = state,
         t
       ) do
    state = fresh_start_time(state)
    at = state.no_clock.at

    with true <- state.no_clock.on?,
         %{session: %{tracker: %{plies: []}} = session, game: %{status: "live"}} <- state,
         false <- Clock.present?(session.clock),
         true <- at == nil or NaiveDateTime.compare(NaiveDateTime.local_now(), at) != :lt do
      Log.add(
        :info,
        "game.started_without_clock",
        %{at: at && NaiveDateTime.to_iso8601(at)},
        ref(state)
      )

      state = %{state | started_without_clock: DateTime.utc_now(:second)}

      state =
        if beginnable?(state),
          do: begin_here(state, t, state.session.tracker.pos.turn),
          else: state

      dirty(state)
    else
      _not_yet -> state
    end
  end

  defp start_without_clock(state, _t), do: state

  # The round's start time may be changed in OpenPairings while the box
  # waits for it: asked again every `@start_time_every_ms`.
  @start_time_every_ms 10_000

  defp fresh_start_time(%{no_clock: no_clock} = state) do
    mono = System.monotonic_time(:millisecond)

    if mono - Map.get(no_clock, :asked, mono) >= @start_time_every_ms,
      do: %{state | no_clock: Map.put(no_clock(state.board), :asked, mono)},
      else: state
  end

  # --- waiting for the memory ----------------------------------------------------

  # Drivers that read a board's memory when they open it.
  @remembering ~w(dgt_serial dgt_bus remote)

  defp wait_for_memory(%{board: %{driver: driver}} = state) when driver in @remembering do
    case Application.get_env(:alnasl, :history_hold_ms, 25_000) do
      ms when is_integer(ms) and ms > 0 ->
        %{state | hold: System.monotonic_time(:millisecond) + ms, held?: false, held_clock: nil}

      _off ->
        state
    end
  end

  defp wait_for_memory(state), do: state

  # The wait is over: the memory did not come in time.
  defp expire_hold(%{hold: hold} = state) when is_integer(hold) do
    if System.monotonic_time(:millisecond) >= hold do
      if state.held?, do: Log.add(:warn, "board.history_late", %{}, ref(state))
      release(state)
    else
      state
    end
  end

  defp expire_hold(state), do: state

  # No more waiting. What was held back is read now, as it stands.
  defp release(%{hold: nil} = state), do: state

  defp release(state) do
    {held?, clock} = {state.held?, state.held_clock}
    state = %{state | hold: nil, held?: false, held_clock: nil}

    state =
      if held? and state.session do
        t = now(state)
        state = if state.seen, do: feed(state, t, {:position, state.seen}), else: state
        if clock, do: feed(state, t, {:clock, clock}), else: state
      else
        state
      end

    dirty(state)
  end

  # A reading that would make the tracker reconstruct moves: guessed, or
  # worked out from the squares.
  defp reconstructs?(events) do
    Enum.any?(events, fn
      {:moves, plies} -> Enum.any?(plies, &(:guessed in &1.flags or :recovered in &1.flags))
      _other -> false
    end)
  end

  defp hold_back(state, event) do
    if not state.held?, do: Log.add(:info, "board.history_waiting", %{}, ref(state))

    clock =
      case event do
        {:clock, reading} -> reading
        _other -> state.held_clock
      end

    %{state | held?: true, held_clock: clock}
  end

  # The game as it is saved now, with a tracker caught up with it.
  defp resume(state, game) do
    late? = state.session.tracker.opts.late_start

    opts =
      Settings.tracker_opts()
      |> Keyword.put(:start_fen, game.start_fen)
      |> Keyword.put(:late_start, late?)

    # The clock goes on as it was: the memory changed the moves, not the time.
    session = %{
      Session.restore(opts, Games.plies(game))
      | clock: state.session.clock,
        swapped?: state.session.swapped?
    }

    %{state | game: game, session: session}
  end

  # Two or more boards answered a single board's questions: it is a loop.
  # There is nothing to ask anybody about that, so it is read as one at
  # once. The switch stops this very process, so it runs beside it, and
  # only once per process: the row it leaves behind, if any, starts afresh.
  defp loop_by_itself(%{board: %Board{driver: "dgt_serial", id: id}}, %{loop: [_, _ | _]}) do
    unless Process.get(:reading_as_loop) do
      Process.put(:reading_as_loop, true)

      Task.Supervisor.start_child(Alnasl.TaskSupervisor, fn ->
        case Alnasl.Boards.get(id) do
          %Board{} = row -> Alnasl.Loops.read_as_loop(row)
          nil -> :gone
        end
      end)
    end

    :ok
  end

  defp loop_by_itself(_state, _info), do: :ok

  # A start position that reads upside down is a board plugged in turned
  # round. Only decided while no move has been made: after that, a board
  # does not turn by itself.
  defp orientation(%{raw: raw, board: board} = state) do
    started? = state.session != nil and state.session.tracker.plies != []
    start = if state.session, do: start_board(state.session.tracker), else: Position.start()

    cond do
      started? or raw == Position.rotate(raw) -> state
      not board.flipped and raw != start and Position.rotate(raw) == start -> flip(state, true)
      board.flipped and raw == start and Position.rotate(raw) != start -> flip(state, false)
      true -> state
    end
  end

  defp start_board(tracker) do
    {:ok, pos} = Chess.parse_fen(tracker.start_fen)
    pos.board
  end

  defp flip(state, flipped?) do
    board = state.board |> Board.changeset(%{flipped: flipped?}) |> Alnasl.Repo.update!()
    Log.add(:info, "board.flipped", %{flipped: flipped?, auto: true}, ref(state))
    Recorder.record(board.id, {:cfg, cfg(board, state.game)})
    %{state | board: board}
  end

  # --- the session -------------------------------------------------------------

  # Time runs on from the last event at the driver's speed - but not past
  # the driver's next event, which has not happened yet.
  defp now(%{time: {t0, mono0, speed, next}, last_t: last}) do
    t = round(t0 + (System.monotonic_time(:millisecond) - mono0) * speed)
    t = if next, do: min(t, next - 1), else: t
    max(t, last)
  end

  defp feed(%{session: nil} = state, _t, _event), do: state

  # The pieces are set up again: the next game, if the box is to begin one
  # by itself (`begin_again?/1`). Otherwise a finished game is finished,
  # whatever the board shows.
  defp feed(state, t, {:position, board} = event) do
    cond do
      set_up_again?(state, board) and begin_again?(state) ->
        state |> new_game(:pieces) |> play(t, event)

      state.game.status == "finished" ->
        state

      true ->
        play(state, t, event)
    end
  end

  defp feed(state, t, event), do: play(state, t, event)

  # The starting position on the board, over a game that is finished - or
  # one that has gone far enough for it to be nothing else: two moves in,
  # the same board is a takeback.
  defp set_up_again?(%{game: game, session: %{tracker: tracker}}, board) do
    board == start_board(tracker) and
      (game.status == "finished" or length(tracker.plies) > tracker.opts.takeback_plies)
  end

  # "Start a new game when the pieces are set up again" (Setup): yes, no,
  # or - the default - only where no pairing says who plays this board in
  # this round. Friends playing game after game want it; a paired round
  # has one game a board, and a board set up early for the next round is
  # not a second game of this one.
  defp begin_again?(%{board: board}) do
    case Settings.get("new_game_on_setup") do
      "always" -> true
      "never" -> false
      _unpaired -> Tournaments.board(board.tournament_id, board.round, board.board_no) == nil
    end
  end

  # A fresh game on this board: the next number, a new tracker, a line in
  # the recording so that a capture can be cut where the games part. A
  # game left unfinished is closed without a result first.
  #
  # `kind` says whether the new game is the board's game of the round (the
  # one that leaves the box, and the one before it stays: `:replace`), or an
  # extra game that stays here (`:extra`); `:auto` is `Games.next_kind/1`:
  # a replacement while a pairing says who plays here and the game that
  # leaves has no result.
  defp new_game(state, by, kind \\ :auto) do
    kind = if kind == :auto, do: Games.next_kind(state.game), else: kind

    state =
      if state.game.status == "finished" do
        state
      else
        Log.add(:info, "result.set", %{result: "*", by: to_string(by)}, ref(state))
        t = now(state)
        closed = %{state | game: Games.finish(state.game, "*")}
        # A game about to be replaced is not announced as closed: its
        # replacement says everything.
        if kind == :replace, do: closed, else: enqueue(closed, t, false)
      end

    game = Games.next(state.game, kind)

    Log.add(
      :info,
      "game.new",
      %{game: game.game_no, by: to_string(by), kind: to_string(kind)},
      ref(state)
    )

    # The board may still show the game before: nothing is read into this
    # one until the starting position has stood on it.
    opts =
      Settings.tracker_opts()
      |> Keyword.put(:start_fen, game.start_fen)
      |> Keyword.put(:late_start, false)

    Recorder.record(state.board.id, {:cfg, cfg(state.board, game)})

    state = %{
      state
      | game: game,
        session: Session.new(opts),
        warning: nil,
        queued_at: nil,
        draft: nil,
        begin_at: nil,
        started_without_clock: nil
    }

    # Every place that holds the game before it is told this is the game now.
    if kind == :replace, do: enqueue(state, now(state), true), else: state
  end

  defp play(state, t, event) do
    state = advance(state, t)
    t = max(t, state.last_t)

    if state.held? do
      hold_back(state, event)
    else
      {session, events} = Session.handle(state.session, t, event)

      if state.hold != nil and reconstructs?(events) do
        hold_back(state, event)
      else
        apply_events(%{state | session: session, last_t: t}, events, t)
      end
    end
  end

  # Ticks the session at each of its own deadlines up to `t`.
  defp advance(%{session: nil} = state, _t), do: state
  defp advance(%{held?: true} = state, _t), do: state
  defp advance(%{game: %{status: "finished"}} = state, _t), do: state

  defp advance(state, t) do
    case Session.deadline(state.session) do
      due when is_integer(due) and due <= t ->
        due = max(due, state.last_t)
        {session, events} = Session.handle(state.session, due, :tick)

        if state.hold != nil and reconstructs?(events) do
          hold_back(state, :tick)
        else
          state = apply_events(%{state | session: session, last_t: due}, events, due)
          if Session.deadline(state.session) == due, do: state, else: advance(state, t)
        end

      _none ->
        state
    end
  end

  # What the session reported becomes: a saved game, a queued update, lines
  # in the log. One queue entry for the lot.
  defp apply_events(state, [], _t), do: state

  defp apply_events(state, events, t) do
    wall = System.os_time(:millisecond)

    {state, queue} =
      Enum.reduce(events, {state, nil}, fn event, {state, queue} ->
        case event do
          {:moves, plies} ->
            {game, _} = Games.apply_event(state.game, event, wall)
            log_moves(state, plies)
            dbg_moves(state, plies)
            {%{state | game: game}, queue || :append}

          {:correction, keep, plies, reason} ->
            {game, _} = Games.apply_event(state.game, event, wall)

            dbg(state, :move, "correction", %{
              keep: keep,
              reason: reason,
              moves: Enum.map(plies, & &1.san)
            })

            case {reason, plies} do
              # A move read wrong and put right: said in so many words.
              {:misread, [%{read: read} = first | _]} ->
                Log.add(
                  :warn,
                  "move.rewritten",
                  %{
                    ply: keep + 1,
                    read: read,
                    now: first.san,
                    moves: Enum.map(plies, & &1.san),
                    sure: :recovered in first.flags
                  },
                  ref(state)
                )

              _other ->
                Log.add(
                  :info,
                  "move.corrected",
                  %{reason: reason, keep: keep, moves: Enum.map(plies, & &1.san)},
                  ref(state)
                )
            end

            {%{state | game: game}, :replace}

          {:restart, fen} ->
            {game, _} = Games.apply_event(state.game, event, wall)
            dbg(state, :move, "restart", %{}, "FEN " <> to_string(fen))
            {%{state | game: game}, :replace}

          {:clock_swapped, from} ->
            {game, _} = Games.apply_event(state.game, event, wall)
            Log.add(:warn, "clock.turned_round", %{from: div(from, 2) + 1}, ref(state))
            {%{state | game: game}, :replace}

          {:status, status, detail} ->
            dbg_status(state, status, detail)
            {log_status(state, status, detail), queue}

          {:result_suggestion, result, why} ->
            {suggest(state, result, why), queue}

          {:clock, _reading} ->
            {state, queue}

          {:unseen, pieces} ->
            log_unseen(state, pieces)
            {state, queue}

          {:dead, squares} ->
            log_dead(state, squares)
            {state, queue}

          {:warning, :move_missing, presses, plies} ->
            Log.add(:warn, "clock.move_missing", %{presses: presses, plies: plies}, ref(state))
            {%{state | warning: :move_missing}, queue}

          {:warning_cleared, :move_missing} ->
            {%{state | warning: nil}, queue}

          # The alarm itself lives in the session (`clock_alarm`); here it
          # is only written down.
          {:warning, :clock_side, side} ->
            Log.add(:error, "clock.wrong_side", %{side: side}, ref(state))
            {state, queue}

          {:warning_cleared, :clock_side} ->
            Log.add(:info, "clock.side_ok", %{}, ref(state))
            {state, queue}

          _other ->
            {state, queue}
        end
      end)

    state = if queue, do: enqueue(state, t, queue == :replace), else: state
    state |> stuck(events) |> dirty()
  end

  defp log_moves(state, plies) do
    flags = plies |> Enum.flat_map(& &1.flags) |> Enum.uniq()
    sans = Enum.map(plies, & &1.san)

    cond do
      :guessed in flags ->
        Log.add(:warn, "move.guessed", %{moves: sans}, ref(state))

      :recovered in flags ->
        Log.add(:warn, "move.recovered", %{moves: sans, long: :long_gap in flags}, ref(state))

      :assumed in flags ->
        Log.add(:warn, "move.assumed", %{moves: sans}, ref(state))

      :arbiter in flags ->
        :ok

      true ->
        :ok
    end
  end

  # A square's sensor was found dead: the newest one, said once.
  defp log_dead(state, squares) do
    Log.add(:warn, "square.dead", %{square: Position.square_name(List.last(squares))}, ref(state))
  end

  # A piece went out of sight and the game went on, or it is accounted for
  # again (seen, moved or taken - the moves say which).
  defp log_unseen(state, []), do: Log.add(:info, "piece.accounted", %{}, ref(state))

  defp log_unseen(state, pieces) do
    for %{square: square, piece: {colour, kind}} = entry <- pieces do
      Log.add(
        :warn,
        "piece.unseen",
        %{
          square: Position.square_name(square),
          colour: colour,
          piece: kind,
          read: entry[:ghost] && Position.square_name(entry.ghost)
        },
        ref(state)
      )
    end
  end

  # Writes down that the board went out of sync - by name, when what it
  # shows has one - and that it is back. `alarmed?` remembers the first so
  # that the second is said once, and only after it.
  defp log_status(state, :out_of_sync, detail) do
    case detail do
      {:out_of_turn, move} ->
        Log.add(
          :error,
          "move.out_of_turn",
          %{
            colour: move.colour,
            move: move.san,
            from: Position.square_name(move.from),
            to: Position.square_name(move.to)
          },
          ref(state)
        )

      {:illegal, %{piece: {colour, kind}} = move} ->
        Log.add(
          :error,
          "move.illegal",
          %{
            colour: colour,
            piece: kind,
            from: Position.square_name(move.from),
            to: Position.square_name(move.to),
            why: move.why
          },
          ref(state)
        )

      other ->
        Log.add(:error, "board.out_of_sync", %{why: inspect(other)}, ref(state))
    end

    Map.put(state, :alarmed?, true)
  end

  defp log_status(%{alarmed?: true} = state, status, _detail)
       when status in [:live, :waiting_start] do
    Log.add(:info, "board.resumed", %{}, ref(state))
    %{state | alarmed?: false}
  end

  defp log_status(state, _status, _detail), do: state

  # A result the board suggests. Kept for the arbiter; sent on by itself only
  # for what is a fact of the position, and only when Setup says so.
  defp suggest(state, result, why) do
    if state.game.suggestion == result do
      state
    else
      Log.add(:info, "result.suggested", %{result: result, why: why}, ref(state))
      dbg_result_why(state, result, why)
      state = %{state | game: Games.suggest(state.game, result)}
      fact? = why in [:checkmate, :stalemate, :insufficient_material]
      auto? = Settings.get("auto_suggest") == true

      if fact? and auto? do
        dbg(state, :result, "result.auto", %{result: result})
        Log.add(:info, "result.set", %{result: result, by: "board"}, ref(state))
        %{state | game: Games.finish(state.game, result)}
      else
        dbg(state, :result, "result.waits", %{result: result, fact: fact?, auto: auto?})
        state
      end
    end
  end

  defp enqueue(state, t, replace?, why \\ :change) do
    reading = Clock.read(state.session.clock, t)

    game =
      state.game
      |> Games.remember_clock(reading && Map.put(reading, :running, reading.running))
      |> Outbox.enqueue(reading, replace?)

    dbg(
      state,
      :sent,
      "queued",
      %{replace: replace?, why: why, plies: length(state.session.tracker.plies), seq: game.seq},
      reading && clock_text(reading)
    )

    %{
      state
      | game: game,
        queued_at: System.monotonic_time(:millisecond)
    }
    |> Map.put(:queued_clock, reading && {reading, t})
  end

  # The server is told the clock when it says something the server cannot
  # work out for itself, and now and then while it runs, so a spectator's
  # countdown does not wander:
  #
  #   * the lever was pressed, or the clock started or stopped - a move is
  #     reported the moment the board sees it, and the press that follows it
  #     comes a second later; without this the server spent up to a heartbeat
  #     counting down the side that had just moved;
  #   * a time moved by more than counting down explains: the arbiter's two
  #     minutes, or any other correction, running or stopped;
  #   * nothing of the sort for `heartbeat_ms`, while it runs.
  defp heartbeat(%{session: nil} = state, _t), do: state
  defp heartbeat(%{game: %{status: "finished"}} = state, _t), do: state

  defp heartbeat(state, t) do
    every = state.heartbeat_ms
    since = state.queued_at && System.monotonic_time(:millisecond) - state.queued_at
    clock = state.session.clock

    with true <- Clock.present?(clock),
         %{running: running} = reading <- Clock.read(clock, t),
         true <- state.session.tracker.plies != [],
         true <-
           clock_news?(Map.get(state, :queued_clock), reading, t, clock.hourglass?) or
             (running != :none and (since == nil or since >= every)) do
      enqueue(state, t, false, :heartbeat)
    else
      _no -> state
    end
  end

  # Readings come a second apart and are whole seconds; a time that is off
  # what counting down predicts by more than this was set, not spent.
  @clock_slack_ms 1_500

  defp clock_news?(nil, _reading, _t, _hourglass?), do: true

  defp clock_news?({sent, sent_t}, reading, t, hourglass?) do
    gone = max(t - sent_t, 0)

    predicted = fn side ->
      ms = Map.get(sent, side)
      running? = sent.running == if(side == :white_ms, do: :white, else: :black)
      if is_integer(ms) and running?, do: max(ms - gone, 0), else: ms
    end

    off? = fn side ->
      now = Map.get(reading, side)
      expected = predicted.(side)
      is_integer(now) and is_integer(expected) and abs(now - expected) > @clock_slack_ms
    end

    # On an hourglass the waiting side's time grows by itself: only the
    # running side's says anything.
    sides =
      cond do
        not hourglass? -> [:white_ms, :black_ms]
        reading.running == :white -> [:white_ms]
        reading.running == :black -> [:black_ms]
        true -> []
      end

    sent.running != reading.running or Enum.any?(sides, off?)
  end

  defp dirty(state), do: %{state | dirty?: true}

  defp ref(%{board: board}),
    do: %{board_id: board.id, round: board.round, board_no: board.board_no}

  # --- calls -------------------------------------------------------------------

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call({:reload, %Board{} = board}, _from, state) do
    relink? =
      {board.tournament_id, board.round, board.board_no} !=
        {state.board.tournament_id, state.board.round, state.board.board_no}

    state = %{
      state
      | board: board,
        heartbeat_ms: (Settings.get("clock_heartbeat_s") || 20) * 1000
    }

    state =
      if relink?,
        do: state |> load_game() |> catch_up() |> refeed() |> linked_mid_game(),
        else: state

    if relink? and state.livechess, do: LiveChessMatch.linked(board.id)
    {:reply, :ok, dirty(state)}
  end

  def handle_call({:livechess_match, match}, _from, %{livechess: %{} = lc} = state),
    do: {:reply, :ok, dirty(%{state | livechess: %{lc | match: match}})}

  def handle_call({:livechess_match, _match}, _from, state), do: {:reply, :ok, state}

  # Somebody else wrote to the game's row - the names, a pairing flag: read
  # it again. The moves are this process's and are in the row already.
  def handle_call(:reload_game, _from, %{game: %{id: id}} = state) do
    case Alnasl.Repo.get(Games.Game, id) do
      nil -> {:reply, :ok, state |> load_game() |> refeed() |> dirty()}
      game -> {:reply, :ok, dirty(%{state | game: game})}
    end
  end

  def handle_call(:reload_game, _from, state), do: {:reply, :ok, state}

  def handle_call({:flip, flipped?}, _from, state) do
    board = state.board |> Board.changeset(%{flipped: flipped?}) |> Alnasl.Repo.update!()
    Log.add(:info, "board.flipped", %{flipped: flipped?, auto: false}, ref(state))
    Recorder.record(board.id, {:cfg, cfg(board, state.game)})
    {:reply, :ok, refeed(%{state | board: board})}
  end

  def handle_call({:driver, :pause}, _from, state),
    do: {:reply, player(state, :pause), dirty(state)}

  def handle_call({:driver, :resume}, _from, state),
    do: {:reply, player(state, :resume), dirty(state)}

  def handle_call({:note, text}, _from, state) do
    Recorder.record(state.board.id, {:note, text})
    {:reply, :ok, state}
  end

  def handle_call({:repair, _op, _args}, _from, %{session: nil} = state),
    do: {:reply, {:error, :not_linked}, state}

  def handle_call({:repair, op, args}, _from, state) do
    {reply, state} = repair(state, op, args, now(state))
    {:reply, reply, dirty(state)}
  end

  defp player(%{driver: pid, board: %{driver: driver}}, action)
       when is_pid(pid) and driver in ["simulator", "replay"] do
    apply(Arkab.Driver.Player, action, [pid])
  end

  defp player(_state, _action), do: {:error, :not_a_player}

  # After a change of game or orientation, the board as it reads now is
  # looked at afresh.
  defp refeed(%{raw: nil} = state), do: state

  defp refeed(state) do
    seen = if state.board.flipped, do: Position.rotate(state.raw), else: state.raw
    feed(%{state | seen: seen}, now(state), {:position, seen})
  end

  # --- the repair tools --------------------------------------------------------

  defp repair(state, :undo, _args, t) do
    last = List.last(Tracker.sans(state.session.tracker))
    tracked(state, t, &Tracker.undo(&1, t), "repair.undo", %{move: last})
  end

  defp repair(state, :append, sans, t) do
    case Tracker.append(state.session.tracker, t, sans) do
      {:ok, result} -> tracked(state, t, fn _tr -> result end, "repair.append", %{moves: sans})
      {:error, {index, message}} -> {{:error, {index, message}}, state}
    end
  end

  defp repair(state, :edit, {number, san}, t) do
    case Tracker.edit(state.session.tracker, t, number, san) do
      {:ok, result, dropped} ->
        {_reply, state} =
          tracked(state, t, fn _tr -> result end, "repair.edit", %{
            ply: number,
            move: san,
            dropped: dropped
          })

        {{:ok, dropped}, state}

      {:error, message} ->
        {{:error, message}, state}
    end
  end

  defp repair(state, :set_fen, fen, t) do
    case Tracker.set_position(state.session.tracker, t, fen) do
      {:ok, result} -> tracked(state, t, fn _tr -> result end, "repair.set_fen", %{fen: fen})
      {:error, message} -> {{:error, message}, state}
    end
  end

  defp repair(state, :resync, depth, t) do
    {tracker, events, outcome} = Tracker.resync(state.session.tracker, t, depth)

    {word, moves} =
      case outcome do
        {:accepted, sans} -> {"accepted", sans}
        {:guessed, sans, _others} -> {"guessed", sans}
        {:rejected, sans} -> {"rejected", sans}
        other -> {to_string(other), []}
      end

    {_reply, state} =
      tracked(state, t, fn _tr -> {tracker, events} end, "repair.resync", %{
        outcome: word,
        moves: moves
      })

    {{:ok, outcome}, state}
  end

  defp repair(state, :choose, {number, sans}, t) do
    case Tracker.choose(state.session.tracker, t, number, sans) do
      {:ok, result, dropped} ->
        {_reply, state} =
          tracked(state, t, fn _tr -> result end, "repair.choose", %{
            ply: number,
            moves: sans,
            dropped: dropped
          })

        {{:ok, dropped}, state}

      {:error, message} ->
        {{:error, message}, state}
    end
  end

  defp repair(state, :alternatives, number, _t),
    do: {{:ok, Tracker.alternatives(state.session.tracker, number)}, state}

  defp repair(state, :result, result, t) when is_binary(result),
    do: repair(state, :result, {result, "arbiter"}, t)

  defp repair(state, :result, {result, by}, t) do
    if result in Alnasl.Games.Game.results() do
      dbg(state, :result, "result.by_hand", %{
        result: result,
        by: by,
        suggestion: state.game.suggestion
      })

      Log.add(:info, "result.set", %{result: result, by: by}, ref(state))
      state = %{state | game: Games.finish(state.game, result)}
      {:ok, enqueue(state, t, false)}
    else
      {{:error, :bad_result}, state}
    end
  end

  # "New game on this board": the arbiter's word, whatever the board shows.
  # `kind`: `:auto` (the rule), `:extra` (it stays here) or `:replace` (it
  # is the game of the pairing).
  defp repair(state, :new_game, kind, _t) do
    state = new_game(state, :arbiter, kind || :auto)
    {:ok, refeed(state)}
  end

  # "Send this one instead": the game on the board becomes the one that
  # leaves the box, and the one that was leaving is kept at home.
  defp repair(state, :send_this, _args, t) do
    game = Games.make_sendable(state.game)
    Log.add(:info, "game.switched", %{game: game.game_no}, ref(state))
    {:ok, enqueue(%{state | game: game}, t, true)}
  end

  # The pairing changed under this game and the arbiter says it is not the
  # new pairing's: it is kept on the box, and the board begins again for
  # whoever is paired here now. The new game is the one that leaves the box,
  # so every destination is told to replace what it holds.
  defp repair(state, :set_aside, _args, t) do
    board = state.board
    pairing = Tournaments.board(board.tournament_id, board.round, board.board_no)
    {_aside, game} = Games.set_aside(state.game, pairing)
    Log.add(:info, "pairing.set_aside", %{game: game.game_no}, ref(state))

    opts =
      Settings.tracker_opts()
      |> Keyword.put(:start_fen, game.start_fen)
      |> Keyword.put(:late_start, false)

    Recorder.record(board.id, {:cfg, cfg(board, game)})

    state = %{
      state
      | game: game,
        session: Session.new(opts),
        warning: nil,
        queued_at: nil,
        draft: nil,
        begin_at: nil,
        started_without_clock: nil
    }

    {:ok, state |> enqueue(t, true) |> refeed()}
  end

  defp repair(state, :reopen, _args, t) do
    Log.add(:info, "result.reopened", %{}, ref(state))
    state = %{state | game: Games.reopen(state.game)}
    {:ok, state |> enqueue(t, true) |> refeed()}
  end

  defp repair(state, :pause, paused?, t) do
    Log.add(:info, if(paused?, do: "repair.paused", else: "repair.resumed"), %{}, ref(state))
    state = %{state | game: Games.pause(state.game, paused?)}
    # Resuming says everything that was held back, in one statement.
    {:ok, if(paused?, do: state, else: enqueue(state, t, true))}
  end

  # The board's memory had another version of this game, and the arbiter
  # takes it. From where the two part; from the start when the memory's game
  # began somewhere else. Only while the game still begins the way it did
  # when the draft was made: a draft that has been overtaken is not played
  # over moves it never saw.
  defp repair(state, :accept_draft, id, t) do
    with %MemoryDrafts.Draft{status: "pending"} = draft <- MemoryDrafts.get(id),
         true <- draft.game_id == state.game.id,
         plies = MemoryDrafts.plies(draft),
         {:ok, events} <- draft_events(state.game, draft, plies) do
      state = apply_events_as_arbiter(state, events)
      MemoryDrafts.settle(draft, "accepted")

      Log.add(
        :info,
        "draft.accepted",
        %{from: draft.from_ply, count: length(plies) - draft.from_ply, by: "arbiter"},
        ref(state)
      )

      state = state |> resume(state.game) |> with_draft()
      {:ok, state |> enqueue(t, true) |> refeed()}
    else
      {:error, why} -> {{:error, why}, state}
      _gone_or_settled -> {{:error, :no_draft}, with_draft(state)}
    end
  end

  defp repair(state, :dismiss_draft, id, _t) do
    case MemoryDrafts.get(id) do
      %MemoryDrafts.Draft{status: "pending", game_id: game_id} = draft
      when game_id == state.game.id ->
        MemoryDrafts.settle(draft, "dismissed")
        Log.add(:info, "draft.dismissed", %{by: "arbiter"}, ref(state))
        {:ok, with_draft(state)}

      _gone_or_settled ->
        {{:error, :no_draft}, with_draft(state)}
    end
  end

  defp repair(state, _unknown, _args, _t), do: {{:error, :unknown}, state}

  defp draft_events(game, draft, plies) do
    own = Games.sans(game)
    from = draft.from_ply
    same_start? = draft.start_fen == (game.start_fen || Chess.start_fen())

    cond do
      not same_start? ->
        {:ok, [{:restart, draft.start_fen}, {:moves, plies}]}

      Enum.take(own, from) == plies |> Enum.take(from) |> Enum.map(& &1.san) and
          length(own) >= from ->
        {:ok, [{:correction, from, Enum.drop(plies, from), :memory}]}

      true ->
        {:error, :overtaken}
    end
  end

  # Applies a tracker operation, saves and queues what it changed (always as
  # a replacement: the arbiter has spoken), and logs who did it.
  defp tracked(state, t, fun, kind, data, by \\ "arbiter") do
    {session, events} = Session.with_tracker(state.session, t, fun)
    Log.add(:info, kind, Map.put(data, :by, by), ref(state))
    state = %{state | session: session, last_t: max(t, state.last_t)}
    changed? = Enum.any?(events, &(elem(&1, 0) in [:moves, :correction, :restart]))
    state = apply_events_as_arbiter(state, events)
    {:ok, if(changed?, do: enqueue(state, t, true), else: state)}
  end

  defp apply_events_as_arbiter(state, events) do
    wall = System.os_time(:millisecond)

    Enum.reduce(events, state, fn event, state ->
      case event do
        {kind, _} when kind in [:moves, :restart] ->
          {game, _} = Games.apply_event(state.game, event, wall)
          %{state | game: game}

        {:correction, _, _, _} ->
          {game, _} = Games.apply_event(state.game, event, wall)
          %{state | game: game}

        {:status, status, detail} ->
          log_status(state, status, detail)

        {:result_suggestion, result, why} ->
          suggest(state, result, why)

        {:unseen, pieces} ->
          log_unseen(state, pieces)
          state

        {:dead, squares} ->
          log_dead(state, squares)
          state

        _other ->
          state
      end
    end)
  end

  # --- the debug log (`Alnasl.BoardLog`) ----------------------------------------
  #
  # What a person who knows DGT boards wants to see when a board does
  # something odd: what it read, what was made of it, and why. The words
  # are `AlnaslWeb.BoardLogWords`'; here are only the facts.

  defp dbg(state, cat, kind, data \\ %{}, tech \\ nil, level \\ :info),
    do: BoardLog.add(state.board.id, cat, kind, data, tech, level)

  # A reading: the squares that changed since the one before, and whether
  # it was used at all.
  defp log_position(state, before, seen) do
    changes =
      if before,
        do: for(sq <- Position.diff(before, seen), do: {sq, elem(before, sq), elem(seen, sq)})

    unless changes == [] do
      use =
        cond do
          state.session == nil -> :unlinked
          state.game.status == "finished" -> :finished
          state.held? -> :held
          true -> nil
        end

      dbg(
        state,
        :position,
        "position",
        %{changes: changes, use: use, flipped: state.board.flipped},
        "placement " <> Position.placement(seen) <> rx_text(state.last_rx)
      )
    end
  end

  defp rx_text(bytes) when is_binary(bytes) and bytes != "" do
    hex =
      bytes
      |> binary_part(0, min(byte_size(bytes), 48))
      |> Base.encode16()
      |> String.replace(~r/(..)(?!$)/, "\\1 ")

    "\nlast rx " <> hex <> if(byte_size(bytes) > 48, do: " ...", else: "")
  end

  defp rx_text(_none), do: ""

  # Only what changes the story: the first reading, a press, a start, a
  # stop. A running clock reads every second, and a line a second is noise.
  defp log_clock(state, before, reading, pressed?) do
    running = Map.get(reading, :running, :none)

    {kind, data} =
      cond do
        not Clock.present?(before) -> {"clock.first", %{running: running}}
        pressed? -> {"clock.pressed", %{from: before.running, to: running}}
        before.running == :none and running != :none -> {"clock.started", %{side: running}}
        before.running != :none and running == :none -> {"clock.stopped", %{}}
        true -> {nil, nil}
      end

    if kind, do: dbg(state, :clock, kind, data, clock_text(reading))
  end

  defp clock_text(reading) do
    "white #{ms_text(reading[:white_ms])}, black #{ms_text(reading[:black_ms])}, " <>
      "running #{reading[:running] || :none}" <>
      if(reading[:armed], do: ", armed #{reading[:armed]}", else: "")
  end

  defp ms_text(ms) when is_integer(ms) do
    s = div(max(ms, 0), 1000)
    h = div(s, 3600)
    m = s |> rem(3600) |> div(60)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(rem(s, 60))}", else: "#{m}:#{pad.(rem(s, 60))}"
  end

  defp ms_text(_none), do: "-"

  # Each move the tracker took, with the piece, the squares, how it knows
  # (the flags) and the positions it was legal from and led to.
  defp dbg_moves(state, plies) do
    tracker = state.session.tracker
    all = tracker.plies
    first = length(all) - length(plies)

    plies
    |> Enum.with_index(first)
    |> Enum.each(fn {ply, index} ->
      before =
        cond do
          Map.get(Enum.at(all, index) || %{}, :san) != ply.san -> nil
          index == 0 -> tracker.start_fen || Chess.start_fen()
          true -> Map.get(Enum.at(all, index - 1), :fen)
        end

      piece =
        with fen when is_binary(fen) <- before,
             board when board != nil <- Position.from_fen(fen),
             from when is_integer(from) <- ply[:from],
             do: elem(board, from),
             else: (_none -> nil)

      flags = ply[:flags] || []

      dbg(
        state,
        :move,
        "move",
        %{
          san: ply.san,
          from: is_integer(ply[:from]) && Position.square_name(ply.from),
          to: is_integer(ply[:to]) && Position.square_name(ply.to),
          piece: piece,
          flags: flags,
          read: ply[:read]
        },
        "from FEN #{before || "?"}\nto FEN #{ply[:fen] || "?"}",
        if(:guessed in flags or :assumed in flags, do: :warn, else: :info)
      )
    end)
  end

  defp dbg_status(state, status, detail) do
    tech = if is_map(detail) or is_tuple(detail), do: inspect(detail, limit: 12)
    level = if status == :out_of_sync, do: :warn, else: :info
    dbg(state, :position, "status", %{status: status, detail: detail}, tech, level)
  end

  # Why the board thinks the game is over, in full: which squares the kings
  # stand on for the gesture, who is mated or stalemated and after what.
  defp dbg_result_why(state, result, why) do
    tracker = state.session.tracker
    fen = Tracker.fen(tracker)
    last = List.last(tracker.plies)

    data =
      case why do
        :gesture ->
          squares = if state.seen, do: Tuple.to_list(state.seen), else: []

          king = fn colour ->
            case Enum.find_index(squares, &(&1 == {colour, :k})) do
              nil -> nil
              i -> Position.square_name(i)
            end
          end

          %{result: result, why: why, white_king: king.(:w), black_king: king.(:b)}

        _fact ->
          %{result: result, why: why, turn: tracker.pos.turn, last: last && last.san}
      end

    dbg(state, :result, "result.why", data, "FEN " <> fen)
  end

  # --- what the site sees ------------------------------------------------------

  # "Out of sync, unexplained" is true but useless when the board stands in
  # the starting position and the game already has moves: somebody set up
  # for a new game on a board still linked to the old one (2026-10-20, a
  # board linked to yesterday's game). Said by name, so the game page can
  # say what to do about it.
  defp detail(%{seen: seen}, %{status: :out_of_sync, detail: :unexplained, plies: [_ | _]} = tr)
       when seen != nil do
    if Position.to_text(seen) == Position.to_text(Position.start()),
      do: {:set_up_again, length(tr.plies)},
      else: tr.detail
  end

  defp detail(_state, tracker), do: tracker.detail

  defp snapshot(state) do
    board = state.board
    tracker = state.session && state.session.tracker
    t = now(state)

    base = %{
      id: board.id,
      name: board.name,
      driver: board.driver,
      port: board.port,
      address: board.address,
      tournament_id: board.tournament_id,
      round: board.round,
      board_no: board.board_no,
      table_no: board.table_no,
      flipped: board.flipped,
      serial: board.serial,
      firmware: board.firmware,
      running?: true,
      connected?: state.connected?,
      last_seen: state.last_seen,
      stats: state.stats,
      info: state.info,
      raw: state.seen && Position.to_text(state.seen),
      warning: state.warning,
      player:
        if(is_pid(state.driver) and board.driver in ["simulator", "replay"],
          do: Arkab.Driver.Player.progress(state.driver)
        ),
      linked?: tracker != nil,
      # The clock beside the board, linked to a game or not: the boards page
      # shows it, so an arbiter can see the clock is in and talking before
      # a game is ever linked.
      board_clock: Clock.read(state.clock, t),
      livechess: state.livechess
    }

    if tracker do
      game = state.game
      last = List.last(tracker.plies)

      Map.merge(base, %{
        status: ui_status(state, tracker),
        detail: detail(state, tracker),
        fen: Tracker.fen(tracker),
        certain: Position.to_text(tracker.pos.board),
        start_fen: tracker.start_fen,
        last_move: last && {last.from, last.to},
        plies: Enum.map(tracker.plies, &Map.take(&1, [:san, :flags, :read])),
        unseen:
          for(
            %{square: sq, piece: piece} = entry <- Tracker.unseen(tracker),
            do: if(entry[:ghost], do: {sq, piece, entry.ghost}, else: {sq, piece})
          ),
        dead: Tracker.dead(tracker),
        confused:
          for(
            %{square: sq, piece: piece, read: read} <- Tracker.confused(tracker),
            do: {sq, piece, read}
          ),
        clock: Clock.read(state.session.clock, t),
        clock_check: Session.clock_check(state.session),
        clock_alarm: state.session.clock_alarm,
        white: game.white,
        black: game.black,
        result: game.result,
        suggestion: game.suggestion,
        paused: game.paused,
        game_status: game.status,
        game_id: game.id,
        game_no: game.game_no,
        local: game.local,
        pairing_flag: game.pairing_flag,
        draft: state.draft,
        no_clock: state.no_clock.on?,
        no_clock_at: state.no_clock.at,
        started_without_clock: state.started_without_clock,
        problems:
          if(tracker.plies == [] and state.seen,
            do: Position.problems(start_board(tracker), state.seen),
            else: []
          )
      })
    else
      Map.merge(base, %{
        status: if(state.connected?, do: :unlinked, else: :no_signal),
        detail: nil,
        plies: [],
        unseen: [],
        dead: [],
        confused: [],
        clock: nil,
        # Which way it stands is found out when it is started: here only
        # whether it is there.
        clock_check: if(Clock.present?(state.clock), do: :ok),
        clock_alarm: nil,
        draft: nil,
        problems: if(state.seen, do: Position.problems(Position.start(), state.seen), else: [])
      })
    end
  end

  # The one word on the tile.
  defp ui_status(state, tracker) do
    cond do
      state.game.status == "finished" -> :finished
      not state.connected? -> :no_signal
      tracker.status == :out_of_sync -> :out_of_sync
      state.session.clock_alarm != nil -> :clock_alarm
      # The clock was there and is not any more: unplugged, switched off,
      # or a battery that gave up. The moves go on; their times do not.
      state.session.clock.off? -> :clock_lost
      # Begun without a clock at the round's start time: White is thinking.
      state.started_without_clock != nil and tracker.status == :waiting_start -> :live
      tracker.status == :live and recovered?(tracker) -> :recovered
      true -> tracker.status
    end
  end

  defp recovered?(%{plies: plies}) do
    case List.last(plies) do
      %{flags: flags} -> :recovered in flags or :guessed in flags
      nil -> false
    end
  end
end
